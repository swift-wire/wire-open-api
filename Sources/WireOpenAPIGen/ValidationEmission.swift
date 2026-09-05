// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

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

    /// Every `pattern` this spec will emit, in a stable order, so `_p0`/`_p1` mean the same thing at
    /// every emission site.
    ///
    /// Computed once rather than accumulated while emitting: response checks are emitted from the
    /// *forwarder*, which is a different traversal from the one that declares the constants, and an
    /// index handed out by one would mean nothing to the other. Walking twice is free — this is a
    /// build-time list of strings.
    var patternPool: [String] {
        var found: [String] = []
        var visitedSchemas: Set<String> = []
        func walk(_ node: SpecAssertions) {
            switch node {
            case .string(_, _, let pattern):
                if let pattern, !found.contains(pattern) { found.append(pattern) }
            case .array(_, _, _, let items): walk(items)
            case .object(let properties): properties.forEach { walk($0.assertions) }
            case .composed(let members): members.forEach { walk($0.assertions) }
            case .reference(let name):
                guard visitedSchemas.insert(name).inserted else { return }
                componentSchemas[name].map(walk)
            case .none, .integer, .number, .unrepresentable: return
            }
        }
        for operationID in operationRoutes.keys.sorted() {
            guard let entry = byOperationID[operationID] else { continue }
            requestRoots(for: entry.operation).forEach { walk($0.node) }
            responseRoots(for: entry.operation).forEach { walk($0.node) }
        }
        return found
    }

    /// The documented responses this operation can construct that assert something — empty unless
    /// `wire-openapi.yaml` asks for response validation.
    func responseRoots(for operation: DiscoveredOperation) -> [(code: Int, node: SpecAssertions)] {
        guard settings.validatesResponses else { return [] }
        return (operationRoutes[operation.operationID]?.responses ?? [])
            .map { (code: $0.code, node: $0.assertions) }
    }

    /// The operations of this spec that assert anything, in a stable order.
    var validatedOperations: [(controller: DiscoveredController, operation: DiscoveredOperation)] {
        byOperationID.sorted { $0.key < $1.key }
            .map(\.value)
            // Response roots count too: an operation whose *only* assertions are on what it returns
            // still needs the enum to exist, because its response check calls a validator declared there.
            .filter {
                !requestAssertions(for: $0.operation).isEmpty
                    || responseRoots(for: $0.operation).contains { carriesChecks($0.node) }
            }
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
        for (_, entry) in byOperationID {
            requestAssertions(for: entry.operation).forEach { walk($0.node) }
            // Responses too, when they are checked: a schema reachable only from a response still needs
            // its validator emitted, or the response check calls a function nobody declared. The same
            // trap the request side hit, arriving from the other direction.
            responseRoots(for: entry.operation).forEach { walk($0.node) }
        }
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
        // Only operations with *request* assertions get an entry point; the rest are here solely so the
        // schema validators their response checks call are declared.
        let entryPoints = operations.filter { !requestAssertions(for: $0.operation).isEmpty }
        let pool = patternPool
        let schemas = reachableSchemas()
            .filter { componentSchemas[$0].map(carriesChecks) ?? false }
            .map { schemaValidator($0, pool: pool) }
        let functions = entryPoints.map { operationValidator($0.operation, pool: pool) }
        let constants = pool.enumerated()
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
    private func schemaValidator(_ name: String, pool: [String]) -> String {
        let body = checks(
            for: componentSchemas[name] ?? .none,
            at: EmissionSite(access: "value", path: "\\(path)", location: "location", indent: "        "),
            pool: pool
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
    private func operationValidator(_ operation: DiscoveredOperation, pool: [String]) -> String {
        let member = GeneratorSafeNames.swiftMemberName(for: operation.operationID, strategy: namingStrategy)
        var blocks: [String] = []
        for parameter in operationRoutes[operation.operationID]?.parameters ?? []
        where carriesChecks(parameter.assertions) {
            blocks.append(
                checks(
                    for: parameter.assertions,
                    at: EmissionSite(
                        access: "input.\(inputMember(for: parameter))",
                        path: "\(parameter.location.rawValue).\(parameter.name)",
                        location: ".\(parameter.location.rawValue)",
                        indent: "        "
                    ),
                    pool: pool
                )
            )
        }
        if let body = operationRoutes[operation.operationID]?.requestBody, carriesChecks(body.assertions) {
            // `if case`, not a `switch`: the enum has one case per documented content type, and only the
            // JSON one carries a value a validator can walk. Matching just that case keeps this correct
            // however many others the document declares.
            let pattern = body.isRequired ? ".json(let wireOpenAPIBody)" : ".some(.json(let wireOpenAPIBody))"
            let bodySite = EmissionSite(
                access: "wireOpenAPIBody",
                path: "body",
                location: ".body",
                indent: "            "
            )
            blocks.append(
                """
                        if case \(pattern) = input.body {
                \(checks(for: body.assertions, at: bodySite, pool: pool))
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

/// Where a check is being emitted.
///
/// Five values travelled together through every recursive call — what to read, what path to report, which
/// location decides the status, which accumulator to record into, and how far to indent. As separate
/// arguments each call site was five lines of forwarding and it was easy to pass the wrong one; as a value
/// they move together, and the three ways of stepping down are named rather than open-coded.
struct EmissionSite {
    /// The Swift expression producing the value to check.
    let access: String
    /// The **contents** of a Swift string literal, not a value: at operation level a literal (`body`), and
    /// inside a schema validator `\(path)`, which interpolates the caller's. One representation serves
    /// both, so appending a property is string concatenation either way.
    let path: String
    /// The Swift expression naming the failure's location — a literal (`.query`) at operation level, and
    /// the forwarded `location` parameter inside a schema validator.
    let location: String
    let accumulator: String
    let indent: String
    /// What to prefix a schema validator's name with.
    ///
    /// Empty inside the `Validation` enum, where a sibling resolves bare. Response checks are emitted in
    /// the *conformer* — a sibling of `Validation`, not a member — so they have to say `Validation.`.
    let qualifier: String

    init(
        access: String,
        path: String,
        location: String,
        accumulator: String = "wireOpenAPIFailures",
        indent: String,
        qualifier: String = ""
    ) {
        self.access = access
        self.path = path
        self.location = location
        self.accumulator = accumulator
        self.indent = indent
        self.qualifier = qualifier
    }

    /// A property of this object: a step down in both the access and the reported path.
    func property(access: String, named name: String) -> EmissionSite {
        EmissionSite(
            access: access,
            path: "\(path).\(name)",
            location: location,
            accumulator: accumulator,
            indent: indent,
            qualifier: qualifier
        )
    }

    /// An `allOf` member. The access steps down; the **path does not** — `value1`/`value2` are Swift
    /// artefacts with no wire counterpart, since the generated `init(from:)` decodes every member from the
    /// same decoder, so a failure inside one belongs at the parent's path.
    func composedMember(_ index: Int) -> EmissionSite {
        EmissionSite(
            access: "\(access).value\(index)",
            path: path,
            location: location,
            accumulator: accumulator,
            indent: indent,
            qualifier: qualifier
        )
    }

    /// Inside an array's element closure. The accumulator changes because the outer one is `inout` and a
    /// closure cannot capture it; the path becomes the closure's parameter, which the runtime has already
    /// indexed.
    var element: EmissionSite {
        EmissionSite(
            access: "wireOpenAPIItem",
            path: "\\(wireOpenAPIItemPath)",
            location: location,
            accumulator: "wireOpenAPIItemFailures",
            indent: indent + "        ",
            qualifier: qualifier
        )
    }
}

extension DirectDispatchEmitter {
    /// The checks for one node at one site — a dispatch, with each shape's emission named below.
    func checks(for node: SpecAssertions, at site: EmissionSite, pool: [String]) -> String {
        switch node {
        case .none:
            return ""
        case .unrepresentable:
            // Already reported by `diagnoseParameterAssertions`, which fails the build. Reaching here
            // means it did not, so emitting nothing is the safe read.
            return ""
        case .string(let minLength, let maxLength, let pattern):
            return stringCheck(minLength, maxLength, pattern, at: site, pool: pool)
        case .integer(let minimum, let exclusiveMinimum, let maximum, let exclusiveMaximum, let multipleOf):
            return call(
                "integer",
                bounds(minimum, exclusiveMinimum, maximum, exclusiveMaximum, multipleOf),
                at: site
            )
        case .number(let minimum, let exclusiveMinimum, let maximum, let exclusiveMaximum, let multipleOf):
            return call(
                "number",
                bounds(minimum, exclusiveMinimum, maximum, exclusiveMaximum, multipleOf),
                at: site
            )
        case .reference(let name):
            return referenceCall(name, at: site)
        case .array(let minItems, let maxItems, let uniqueItems, let items):
            return arrayCheck(minItems, maxItems, uniqueItems, items, at: site, pool: pool)
        case .object(let properties):
            return objectChecks(properties, at: site, pool: pool)
        case .composed(let members):
            return composedChecks(members, at: site, pool: pool)
        }
    }

    /// Patterns are pooled: one `_pN` constant per distinct expression, however many schemas use it.
    private func stringCheck(
        _ minLength: Int?,
        _ maxLength: Int?,
        _ pattern: String?,
        at site: EmissionSite,
        pool: [String]
    ) -> String {
        var arguments: [String] = []
        if let minLength { arguments.append("minLength: \(minLength)") }
        if let maxLength { arguments.append("maxLength: \(maxLength)") }
        if let pattern {
            // The pool is precomputed, so an unknown pattern is impossible; falling back to no check
            // rather than trapping keeps a codegen slip from becoming a crash in someone's build.
            guard let index = pool.firstIndex(of: pattern) else { return call("string", arguments, at: site) }
            arguments.append("pattern: _p\(index)")
        }
        return call("string", arguments, at: site)
    }

    /// A call, not an expansion: this is what terminates on a recursive schema.
    ///
    /// Emitted only when the target actually asserts something, so this and `validationDeclaration` agree
    /// on which functions exist — they used to disagree, and the output called one that was never
    /// declared.
    private func referenceCall(_ name: String, at site: EmissionSite) -> String {
        guard componentSchemas[name].map(carriesChecks) ?? false else { return "" }
        return """
            \(site.indent)\(site.qualifier)\(schemaFunctionName(name))(
            \(site.indent)    \(site.access), at: "\(site.path)", in: \(site.location), \
            into: &\(site.accumulator)
            \(site.indent))
            """
    }

    private func arrayCheck(
        _ minItems: Int?,
        _ maxItems: Int?,
        _ uniqueItems: Bool,
        _ items: SpecAssertions,
        at site: EmissionSite,
        pool: [String]
    ) -> String {
        var arguments: [String] = []
        if let minItems { arguments.append("minItems: \(minItems)") }
        if let maxItems { arguments.append("maxItems: \(maxItems)") }
        if uniqueItems { arguments.append("uniqueItems: true") }
        let element = checks(for: items, at: site.element, pool: pool)
        guard !element.isEmpty else { return call("array", arguments, at: site) }
        let joined = arguments.isEmpty ? "" : ", " + arguments.joined(separator: ", ")
        return """
            \(site.indent)WireOpenAPIValidate.array(
            \(site.indent)    \(site.access), at: "\(site.path)", in: \(site.location)\(joined),
            \(site.indent)    into: &\(site.accumulator),
            \(site.indent)    element: { wireOpenAPIItem, wireOpenAPIItemPath, wireOpenAPIItemFailures in
            \(element)
            \(site.indent)    }
            \(site.indent))
            """
    }

    private func objectChecks(
        _ properties: [SpecProperty],
        at site: EmissionSite,
        pool: [String]
    ) -> String {
        properties.compactMap { property -> String? in
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
            let access = "\(site.access).\(member)" + (descends && !property.isRequired ? "?" : "")
            return checks(
                for: property.assertions,
                at: site.property(access: access, named: property.name),
                pool: pool
            )
        }
        .joined(separator: "\n")
    }

    private func composedChecks(
        _ members: [SpecComposedMember],
        at site: EmissionSite,
        pool: [String]
    ) -> String {
        members.compactMap { member -> String? in
            guard carriesChecks(member.assertions) else { return nil }
            return checks(for: member.assertions, at: site.composedMember(member.index), pool: pool)
        }
        .joined(separator: "\n")
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

    private func call(_ kind: String, _ arguments: [String], at site: EmissionSite) -> String {
        let joined = arguments.isEmpty ? "" : ", " + arguments.joined(separator: ", ")
        return """
            \(site.indent)WireOpenAPIValidate.\(kind)(
            \(site.indent)    \(site.access), at: "\(site.path)", in: \(site.location)\(joined),
            \(site.indent)    into: &\(site.accumulator)
            \(site.indent))
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

// MARK: - responses

extension DirectDispatchEmitter {
    /// The check for a value the handler is about to return, or nothing when responses are not validated
    /// or this response asserts nothing.
    ///
    /// A separate accumulator and a separate error type from the request checks: the caller broke nothing,
    /// so this is the service's own breach and answers 500 with no body. Reusing the request accumulator
    /// would also mix the two blames in one report.
    func responseCheck(
        _ node: SpecAssertions,
        access: String,
        operationID: String,
        indent: String
    ) -> String {
        guard settings.validatesResponses, carriesChecks(node) else { return "" }
        let site = EmissionSite(
            access: access,
            path: "body",
            location: ".body",
            accumulator: "wireOpenAPIResponseFailures",
            indent: indent,
            qualifier: "\(validationEnum)."
        )
        let body = checks(for: node, at: site, pool: patternPool)
        guard !body.isEmpty else { return "" }
        return """
            \(indent)var wireOpenAPIResponseFailures = WireOpenAPIFailureAccumulator()
            \(body)
            \(indent)if let wireOpenAPIResponseError = wireOpenAPIResponseFailures.responseError(
            \(indent)    operationID: "\(operationID)"
            \(indent)) {
            \(indent)    throw wireOpenAPIResponseError
            \(indent)}

            """
    }

    /// The check for the response a **typed** handler constructs.
    func typedResponseCheck(_ operation: DiscoveredOperation, indent: String) -> String {
        responseCheck(
            selectedResponse(for: operation).assertions,
            access: "wireOpenAPIResult",
            operationID: operation.operationID,
            indent: indent
        )
    }

    /// The checks for a **raw** handler's output.
    ///
    /// A raw handler builds the `Output` itself, so the value has to be destructured back out of it. That
    /// needs no naming this emitter does not already rely on: the case is the status's safe name, which
    /// the typed shim already emits when it *constructs* one, and `.body` / `.json` are the same members
    /// `bodyBinding` reads on an `Input`. `if case` rather than a `switch`, so a document declaring
    /// responses this cannot check still compiles.
    func rawResponseChecks(_ operation: DiscoveredOperation, indent: String) -> String {
        guard settings.validatesResponses else { return "" }
        return (operationRoutes[operation.operationID]?.responses ?? [])
            .filter { carriesChecks($0.assertions) }
            .compactMap { response -> String? in
                let caseName = GeneratorStatusNames.safeName(for: response.code)
                let inner = responseCheck(
                    response.assertions,
                    access: "wireOpenAPIBody",
                    operationID: operation.operationID,
                    indent: indent + "    "
                )
                guard !inner.isEmpty else { return nil }
                return """
                    \(indent)if case .\(caseName)(let wireOpenAPIPayload) = wireOpenAPIOutput,
                    \(indent)    case .json(let wireOpenAPIBody) = wireOpenAPIPayload.body
                    \(indent){
                    \(inner)\(indent)}
                    """
            }
            .joined(separator: "\n")
    }
}
