import Foundation
import WireOpenAPINaming

// Emitting the document's assertions as code.
//
// Nothing here generates a comparison. The awkward parts (counting a string in code points, `multipleOf`
// on a binary float, the nil case) live in `WireOpenAPIValidate` in the runtime, and this emits calls to
// it. That keeps the output readable, keeps the decisions in one place, and means a fix to a check does
// not require regenerating anything.
//
// Two shapes carry most of the design.
//
// **Everything is passed as an `Optional`.** A required member is non-optional and an optional one is
// not, and a non-optional promotes at the call site — so the emitter never has to know which the document
// declared, and cannot get it wrong. The one exception is *descending into an inline object*, where a
// chain needs its `?`; there the document's `required:` list decides, and a disagreement with the
// generator would be a compile error in the output rather than a silent miss.
//
// **A `$ref` becomes a call, never an expansion.** That is what terminates on a recursive schema — a
// `Node` whose children are `Node`s emits one function that calls itself — and what keeps the output
// linear in the document rather than in operations × schema depth. Only a *named* schema needs its Swift
// type spelled; an inline one is walked in place through member access, so
// `Operations.X.Input.Body.JsonPayload.NestedPayload` is a spelling this never has to derive.

extension DirectDispatchEmitter {
    var validationEnum: String { "Validation" }

    /// The operations of this spec that assert anything, in a stable order.
    var validatedOperations: [(controller: DiscoveredController, operation: DiscoveredOperation)] {
        byOperationID.sorted { $0.key < $1.key }
            .map(\.value)
            .filter { !requestAssertions(for: $0.operation).isEmpty }
    }

    /// Every root of an operation's *request*: its parameters, and its JSON body — unfiltered.
    ///
    /// Responses are deliberately absent. They are slice 5's business, and a constraint reachable only
    /// from a response must not fail a build for a feature nobody switched on.
    func requestRoots(for operation: DiscoveredOperation) -> [(path: String, node: SpecAssertions)] {
        guard let route = operationRoutes[operation.operationID] else { return [] }
        var found = route.parameters
            .map { (path: "\($0.location.rawValue).\($0.name)", node: $0.assertions) }
        if let body = route.requestBody { found.append((path: "body", node: body.assertions)) }
        return found
    }

    /// The roots that produce checks — `requestRoots` filtered by what can actually be emitted.
    ///
    /// The two are separate on purpose. `carriesChecks` is false for an `.unrepresentable` node, because
    /// nothing can be emitted for one; filtering the *diagnostic* walk by it would therefore hide exactly
    /// the assertions that most need reporting. Emission filters, diagnosis does not.
    func requestAssertions(for operation: DiscoveredOperation) -> [(path: String, node: SpecAssertions)] {
        requestRoots(for: operation).filter { carriesChecks($0.node) }
    }

    /// `Components.Schemas.<Name>`, and the validator's own name for that schema.
    func schemaTypeName(_ name: String) -> String {
        "Components.Schemas.\(GeneratorSafeNames.swiftTypeName(for: name, strategy: namingStrategy))"
    }

    func schemaFunctionName(_ name: String) -> String { "schema_\(sanitizedKeyFragment(name))" }

    func inputTypeName(_ operation: DiscoveredOperation) -> String {
        operation.inputType ?? "\(operationNamespace(operation)).Input"
    }

    // MARK: - reachability

    /// The component schemas a request can reach, transitively.
    ///
    /// A reference is followed once — the `visited` set is what makes a cycle terminate here as well as
    /// in the emitted code.
    func reachableSchemas() -> [String] {
        var visited: Set<String> = []
        func walk(_ node: SpecAssertions) {
            switch node {
            case .reference(let name):
                guard visited.insert(name).inserted else { return }
                componentSchemas[name].map(walk)
            case .array(_, _, _, let items): walk(items)
            case .object(let properties): properties.forEach { walk($0.assertions) }
            case .composed(let members): members.forEach { walk($0.assertions) }
            case .none, .string, .integer, .number, .unrepresentable: return
            }
        }
        for (_, entry) in byOperationID { requestAssertions(for: entry.operation).forEach { walk($0.node) } }
        return visited.sorted()
    }

    /// Whether a schema leads to any check at all — the **single** predicate deciding both which calls
    /// are emitted and which functions exist to receive them.
    ///
    /// Using two (a structural `isEmpty` at the call site, this at the declaration site) is how the first
    /// draft emitted `schema_Task(...)` against a `Task` that asserts nothing and was therefore never
    /// declared. They cannot be allowed to disagree.
    func carriesChecks(_ node: SpecAssertions) -> Bool {
        var inProgress: Set<String> = []
        return asserts(node, inProgress: &inProgress)
    }

    /// Whether a schema leads to any check at all, following references.
    ///
    /// A schema that merely references assertion-free schemas asserts nothing, and emitting a validator
    /// for it would be dead code. `inProgress` treats a cycle as contributing nothing, which is correct:
    /// a cycle adds no assertion that is not already on one of its members.
    func asserts(_ node: SpecAssertions, inProgress: inout Set<String>) -> Bool {
        switch node {
        case .none, .unrepresentable: return false
        case .string, .integer, .number: return true
        case .array(let minItems, let maxItems, let uniqueItems, let items):
            if minItems != nil || maxItems != nil || uniqueItems { return true }
            return asserts(items, inProgress: &inProgress)
        case .object(let properties):
            return properties.contains { asserts($0.assertions, inProgress: &inProgress) }
        case .composed(let members):
            return members.contains { asserts($0.assertions, inProgress: &inProgress) }
        case .reference(let name):
            guard inProgress.insert(name).inserted else { return false }
            defer { inProgress.remove(name) }
            guard let target = componentSchemas[name] else { return false }
            return asserts(target, inProgress: &inProgress)
        }
    }

    // MARK: - the namespace

    /// The whole validator for this spec, or nothing when the document asserts nothing.
    ///
    /// Emitting nothing in that case is load-bearing rather than tidy: validation is always on, so a
    /// document that declares no assertions has to cost an existing consumer exactly zero.
    func validationDeclaration() -> String? {
        let operations = validatedOperations
        guard !operations.isEmpty else { return nil }
        var patterns: [String] = []
        let schemas = reachableSchemas()
            .filter { componentSchemas[$0].map(carriesChecks) ?? false }
            .map { schemaValidator($0, patterns: &patterns) }
        let functions = operations.map { operationValidator($0.operation, patterns: &patterns) }
        let constants = patterns.enumerated()
            .map { "    static let _p\($0.offset) = WireOpenAPIPattern(#\"\($0.element)\"#)" }
        return """
            /// Assertions this document makes that the generator does not enforce, checked before the
            /// handler is called. Generated from the document; see Notes/WireOpenAPIValidation.md.
            enum \(validationEnum) {
            \(constants.isEmpty ? "" : constants.joined(separator: "\n") + "\n")
            \((schemas + functions).joined(separator: "\n\n"))
            }
            """
    }

    /// One named component schema's validator.
    ///
    /// Takes an `Optional` so a caller never has to unwrap, and guards on nil so the body can walk members
    /// directly. The `isFull` guard is what stops a huge nested payload from walking after the failure cap
    /// has already been reached.
    private func schemaValidator(_ name: String, patterns: inout [String]) -> String {
        let body = checks(
            for: componentSchemas[name] ?? .none, access: "value", path: "\\(path)",
            location: "location", indent: "        ", patterns: &patterns
        )
        // `location` is a parameter, not a literal: the same component schema can be reached from a
        // request body *and* from a `$ref`'d parameter schema, and the two earn different statuses — 422
        // for a body, 400 for the request line. Baking one in would answer the other wrongly.
        return """
                static func \(schemaFunctionName(name))(
                    _ value: \(schemaTypeName(name))?,
                    at path: String,
                    in location: WireOpenAPIFailureLocation,
                    into wireOpenAPIFailures: inout WireOpenAPIFailureAccumulator
                ) {
                    guard let value, !wireOpenAPIFailures.isFull else { return }
            \(body)
                }
            """
    }

    /// One operation's entry point: its parameters, then its body, then the throw.
    private func operationValidator(_ operation: DiscoveredOperation, patterns: inout [String]) -> String {
        let member = GeneratorSafeNames.swiftMemberName(for: operation.operationID, strategy: namingStrategy)
        var blocks: [String] = []
        for parameter in operationRoutes[operation.operationID]?.parameters ?? []
        where carriesChecks(parameter.assertions) {
            blocks.append(
                checks(
                    for: parameter.assertions,
                    access: "input.\(inputMember(for: parameter))",
                    path: "\(parameter.location.rawValue).\(parameter.name)",
                    location: ".\(parameter.location.rawValue)",
                    indent: "        ",
                    patterns: &patterns
                )
            )
        }
        if let body = operationRoutes[operation.operationID]?.requestBody, carriesChecks(body.assertions) {
            // `if case`, not a `switch`: the enum has one case per documented content type, and only the
            // JSON one carries a value a validator can walk. Matching just that case keeps this correct
            // however many others the document declares.
            let pattern = body.isRequired ? ".json(let wireOpenAPIBody)" : ".some(.json(let wireOpenAPIBody))"
            blocks.append(
                """
                        if case \(pattern) = input.body {
                \(checks(for: body.assertions, access: "wireOpenAPIBody", path: "body", location: ".body", indent: "            ", patterns: &patterns))
                        }
                """
            )
        }
        return """
                static func \(member)(_ input: \(inputTypeName(operation))) throws {
                    var wireOpenAPIFailures = WireOpenAPIFailureAccumulator()
            \(blocks.joined(separator: "\n"))
                    if let wireOpenAPIError = wireOpenAPIFailures.requestError(
                        operationID: "\(operation.operationID)"
                    ) {
                        throw wireOpenAPIError
                    }
                }
            """
    }

    private func inputMember(for parameter: SpecParameter) -> String {
        let member = GeneratorSafeNames.swiftMemberName(for: parameter.name, strategy: namingStrategy)
        return "\(parameter.location.inputMember).\(member)"
    }
}

// MARK: - walking a schema

extension DirectDispatchEmitter {
    /// The checks for one node, at one access expression and one JSON path.
    ///
    /// `path` is the *contents* of a Swift string literal, not a value: at operation level it is a
    /// literal (`body`), and inside a schema validator it is `\(path)`, which interpolates the caller's.
    /// One representation serves both, so appending a property is string concatenation either way.
    func checks(
        for node: SpecAssertions,
        access: String,
        path: String,
        /// The Swift expression naming the failure's location — a literal (`.query`) at operation level,
        /// and the forwarded `location` parameter inside a schema validator.
        location: String,
        accumulator: String = "wireOpenAPIFailures",
        indent: String,
        patterns: inout [String]
    ) -> String {
        switch node {
        case .none:
            return ""
        case .unrepresentable:
            // Already reported by `diagnoseRequestAssertions`, which fails the build. Reaching here means
            // it did not, so emitting nothing is the safe read.
            return ""
        case .string(let minLength, let maxLength, let pattern):
            var arguments: [String] = []
            if let minLength { arguments.append("minLength: \(minLength)") }
            if let maxLength { arguments.append("maxLength: \(maxLength)") }
            if let pattern {
                let index =
                    patterns.firstIndex(of: pattern) ?? { patterns.append(pattern); return patterns.count - 1 }()
                arguments.append("pattern: _p\(index)")
            }
            return call("string", access, path, location, arguments, accumulator, indent)
        case .integer(let minimum, let exclusiveMinimum, let maximum, let exclusiveMaximum, let multipleOf):
            return call(
                "integer", access, path, location,
                bounds(minimum, exclusiveMinimum, maximum, exclusiveMaximum, multipleOf), accumulator, indent
            )
        case .number(let minimum, let exclusiveMinimum, let maximum, let exclusiveMaximum, let multipleOf):
            return call(
                "number", access, path, location,
                bounds(minimum, exclusiveMinimum, maximum, exclusiveMaximum, multipleOf), accumulator, indent
            )
        case .reference(let name):
            // A call, not an expansion: this is what terminates on a recursive schema. Emitted only when
            // the target actually asserts something, so this and `validationDeclaration` agree on which
            // functions exist.
            guard componentSchemas[name].map(carriesChecks) ?? false else { return "" }
            return """
                \(indent)\(schemaFunctionName(name))(
                \(indent)    \(access), at: "\(path)", in: \(location), into: &\(accumulator)
                \(indent))
                """
        case .array(let minItems, let maxItems, let uniqueItems, let items):
            var arguments: [String] = []
            if let minItems { arguments.append("minItems: \(minItems)") }
            if let maxItems { arguments.append("maxItems: \(maxItems)") }
            if uniqueItems { arguments.append("uniqueItems: true") }
            // The element closure gets its own accumulator parameter rather than capturing the outer one,
            // which is `inout` and cannot be captured.
            let element = checks(
                for: items, access: "wireOpenAPIItem", path: "\\(wireOpenAPIItemPath)",
                location: location, accumulator: "wireOpenAPIItemFailures", indent: indent + "        ",
                patterns: &patterns
            )
            guard !element.isEmpty else {
                return call("array", access, path, location, arguments, accumulator, indent)
            }
            let joined = arguments.isEmpty ? "" : ", " + arguments.joined(separator: ", ")
            return """
                \(indent)WireOpenAPIValidate.array(
                \(indent)    \(access), at: "\(path)", in: \(location)\(joined),
                \(indent)    into: &\(accumulator),
                \(indent)    element: { wireOpenAPIItem, wireOpenAPIItemPath, wireOpenAPIItemFailures in
                \(element)
                \(indent)    }
                \(indent))
                """
        case .object(let properties):
            return properties.compactMap { property -> String? in
                guard carriesChecks(property.assertions) else { return nil }
                let member = GeneratorSafeNames.swiftMemberName(for: property.name, strategy: namingStrategy)
                // Only *descending into an inline object* needs the chain: every other shape is passed to
                // something that already takes an `Optional`, so a non-optional member promotes and an
                // optional one is handled. This is the one place the document's `required:` list has to be
                // right, and a disagreement is a compile error in the output rather than a silent miss.
                let descends: Bool
                switch property.assertions {
                case .object, .composed: descends = true
                default: descends = false
                }
                let access = "\(access).\(member)" + (descends && !property.isRequired ? "?" : "")
                return checks(
                    for: property.assertions, access: access, path: "\(path).\(property.name)",
                    location: location, accumulator: accumulator, indent: indent, patterns: &patterns
                )
            }
            .joined(separator: "\n")
        case .composed(let members):
            // The path does **not** gain a segment. `value1`/`value2` are Swift artefacts with no wire
            // counterpart — the generated `init(from:)` decodes every member from the same decoder — so a
            // failure inside one belongs at the parent's path, which is where the caller can find it.
            return members.compactMap { member -> String? in
                guard carriesChecks(member.assertions) else { return nil }
                return checks(
                    for: member.assertions, access: "\(access).value\(member.index)", path: path,
                    location: location, accumulator: accumulator, indent: indent, patterns: &patterns
                )
            }
            .joined(separator: "\n")
        }
    }

    private func bounds(
        _ minimum: (some CustomStringConvertible)?,
        _ exclusiveMinimum: Bool,
        _ maximum: (some CustomStringConvertible)?,
        _ exclusiveMaximum: Bool,
        _ multipleOf: (some CustomStringConvertible)?
    ) -> [String] {
        var arguments: [String] = []
        if let minimum { arguments.append("minimum: \(minimum)") }
        if exclusiveMinimum { arguments.append("exclusiveMinimum: true") }
        if let maximum { arguments.append("maximum: \(maximum)") }
        if exclusiveMaximum { arguments.append("exclusiveMaximum: true") }
        if let multipleOf { arguments.append("multipleOf: \(multipleOf)") }
        return arguments
    }

    private func call(
        _ kind: String,
        _ access: String,
        _ path: String,
        _ location: String,
        _ arguments: [String],
        _ accumulator: String,
        _ indent: String
    ) -> String {
        let joined = arguments.isEmpty ? "" : ", " + arguments.joined(separator: ", ")
        return """
            \(indent)WireOpenAPIValidate.\(kind)(
            \(indent)    \(access), at: "\(path)", in: \(location)\(joined),
            \(indent)    into: &\(accumulator)
            \(indent))
            """
    }
}

// MARK: - the call site

extension DirectDispatchEmitter {
    /// The line the forwarder runs before handing the request to the controller, or nothing when this
    /// operation asserts nothing.
    func validationCall(_ operation: DiscoveredOperation, indent: String) -> String {
        guard !requestAssertions(for: operation).isEmpty else { return "" }
        let member = GeneratorSafeNames.swiftMemberName(for: operation.operationID, strategy: namingStrategy)
        return "\(indent)try \(validationEnum).\(member)(input)\n"
    }
}

// MARK: - diagnostics

extension DirectDispatchEmitter {
    /// An assertion this adapter cannot check is a build error, not a silent omission.
    ///
    /// The rule is the one `diagnoseMappingForm` already applies to responses: where the document asks for
    /// something the adapter cannot construct, say so rather than quietly doing nothing. A document that
    /// declares `minLength` and gets no enforcement is the exact failure this capability exists to remove,
    /// so producing it *silently* would be worse than the gap it replaces.
    ///
    /// **Keyed on request-reachability, not on the schema.** A `Components.Schemas.Task` is routinely both
    /// a request body and a response body, and response validation is not switched on — so failing a build
    /// over a constraint reachable only from a response would fail it for a feature nobody enabled. The
    /// walk therefore starts at each operation's *request* surface. Turning response validation on later
    /// widens the walk, and may legitimately turn a passing build into a failing one.
    func diagnoseParameterAssertions() {
        for (_, entry) in byOperationID.sorted(by: { $0.key < $1.key }) {
            var visited: Set<String> = []
            for root in requestRoots(for: entry.operation) {
                diagnose(root.node, at: root.path, of: entry.operation, visited: &visited)
            }
        }
    }

    private func diagnose(
        _ node: SpecAssertions,
        at path: String,
        of operation: DiscoveredOperation,
        visited: inout Set<String>
    ) {
        switch node {
        case .none, .integer, .number:
            return
        case .array(_, _, _, let items):
            diagnose(items, at: "\(path)[]", of: operation, visited: &visited)
        case .object(let properties):
            for property in properties {
                diagnose(
                    property.assertions, at: "\(path).\(property.name)", of: operation, visited: &visited
                )
            }
        case .composed(let members):
            // Reported at the parent's path, because that is where the caller would see it — `value1` has
            // no wire counterpart.
            for member in members { diagnose(member.assertions, at: path, of: operation, visited: &visited) }
        case .reference(let name):
            // Once per schema per operation: a schema reached from three properties has one problem, not
            // three, and a recursive one would otherwise not terminate.
            guard visited.insert(name).inserted else { return }
            componentSchemas[name].map { diagnose($0, at: path, of: operation, visited: &visited) }
        case .unrepresentable(let keywords, let reason):
            fail(
                """
                '\(path)' in the request of '\(operation.operationID)' declares \
                \(keywords.joined(separator: ", ")), which this adapter cannot check \
                because \(reason). Remove it from the document, or check it in the handler. @RawOperation is \
                not an escape — validation is emitted for those too, from the same document.
                """,
                at: operation
            )
        case .string(_, _, let pattern):
            guard let pattern else { return }
            // Compiled with the same engine the runtime will use, so agreement is by construction rather
            // than by hope — and an unreadable expression fails the build here instead of trapping in
            // `WireOpenAPIPattern.init` on the first request that reaches it.
            guard (try? Regex(pattern)) == nil else { return }
            fail(
                """
                '\(path)' in the request of '\(operation.operationID)' declares \
                `pattern: \(pattern)`, which Swift's regular-expression engine cannot compile. JSON Schema \
                patterns are ECMA-262; most translate directly, but this one does not. Rewrite it, or \
                remove it and check it in the handler.
                """,
                at: operation
            )
        }
    }
}
