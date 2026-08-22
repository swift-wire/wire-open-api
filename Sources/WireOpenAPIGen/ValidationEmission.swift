import Foundation
import WireOpenAPINaming

// Emitting the document's assertions as code — slice 2, which covers an operation's **parameters**.
//
// Nothing here generates a comparison. The awkward parts (counting a string in code points, `multipleOf`
// on a binary float, the nil case) live in `WireOpenAPIValidate` in the runtime, and this emits calls to
// it. That keeps the output readable, keeps the decisions in one place, and means a fix to a check does
// not require regenerating anything.
//
// The one shape worth noticing is that **every value is passed as an `Optional`**. A required parameter
// is a non-optional member and an optional one is not, and a non-optional promotes at the call site — so
// the emitter never has to know which the document declared, and cannot get it wrong. Absence is not a
// failure here: `required` was already enforced by the generator making the member non-optional.
//
// Emission is keyed on the *document*, so it covers `@RawOperation` and `@Operation` alike — a raw
// operation receives the same `Input`, and its author is no less entitled to have the document enforced.

extension DirectDispatchEmitter {
    /// The validator namespace's name, as written inside the spec namespace.
    var validationEnum: String { "Validation" }

    /// The operations of this spec that assert anything, in a stable order.
    var validatedOperations: [(controller: DiscoveredController, operation: DiscoveredOperation)] {
        byOperationID.sorted { $0.key < $1.key }
            .map(\.value)
            .filter { !parameterAssertions(for: $0.operation).isEmpty }
    }

    /// The document's parameters for an operation that assert something, paired with their assertions.
    func parameterAssertions(for operation: DiscoveredOperation) -> [SpecParameter] {
        (operationRoutes[operation.operationID]?.parameters ?? [])
            .filter { !$0.assertions.isEmpty }
    }

    /// `Operations.GetTask.Input`, spelled as the forwarder spells it — verbatim for a raw operation,
    /// derived for a typed one.
    func inputTypeName(_ operation: DiscoveredOperation) -> String {
        operation.inputType ?? "\(operationNamespace(operation)).Input"
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
        let functions = operations.map { validator($0.operation, patterns: &patterns) }
        let constants = patterns.enumerated()
            .map { "    static let _p\($0.offset) = WireOpenAPIPattern(#\"\($0.element)\"#)" }
        return """
            /// Assertions this document makes that the generator does not enforce, checked before the
            /// handler is called. Generated from the document; see Notes/WireOpenAPIValidation.md.
            enum \(validationEnum) {
            \(constants.isEmpty ? "" : constants.joined(separator: "\n") + "\n")
            \(functions.joined(separator: "\n\n"))
            }
            """
    }

    /// One operation's validator.
    private func validator(_ operation: DiscoveredOperation, patterns: inout [String]) -> String {
        let member = GeneratorSafeNames.swiftMemberName(for: operation.operationID, strategy: namingStrategy)
        let checks = parameterAssertions(for: operation)
            .map { parameter in
                check(
                    value: "input.\(inputMember(for: parameter))",
                    path: "\(parameter.location.rawValue).\(parameter.name)",
                    location: parameter.location,
                    assertions: parameter.assertions,
                    indent: "        ",
                    patterns: &patterns
                )
            }
        return """
            \("    ")static func \(member)(_ input: \(inputTypeName(operation))) throws {
                    var wireOpenAPIFailures = WireOpenAPIFailureAccumulator()
            \(checks.joined(separator: "\n"))
                    if let wireOpenAPIError = wireOpenAPIFailures.requestError(
                        operationID: "\(operation.operationID)"
                    ) {
                        throw wireOpenAPIError
                    }
                }
            """
    }

    /// `path.id` / `query.includeDone` / `headers.xRequestId` — the location from the document, the
    /// member spelling from the generator's transform.
    ///
    /// Note the asymmetry with the *reported* path, which uses the parameter's **documented** name:
    /// `query.include-done` is what the caller sent and what they can act on, where `includeDone` is an
    /// artefact of how Swift spells it.
    private func inputMember(for parameter: SpecParameter) -> String {
        let member = GeneratorSafeNames.swiftMemberName(for: parameter.name, strategy: namingStrategy)
        return "\(parameter.location.inputMember).\(member)"
    }

    // MARK: - one check

    /// One `WireOpenAPIValidate` call, or several for an array with element assertions.
    private func check(
        value: String,
        path: String,
        location: SpecParameter.Location,
        assertions: SpecAssertions,
        indent: String,
        patterns: inout [String]
    ) -> String {
        let place = ".\(location == .header ? "header" : location.rawValue)"
        switch assertions {
        case .none, .unrepresentable:
            // `.unrepresentable` has already been reported by `diagnoseParameterAssertions`, which fails
            // the build; reaching here means it did not, so emitting nothing is the safe read.
            return ""
        case .string(let minLength, let maxLength, let pattern):
            var arguments: [String] = []
            if let minLength { arguments.append("minLength: \(minLength)") }
            if let maxLength { arguments.append("maxLength: \(maxLength)") }
            if let pattern {
                let index =
                    patterns.firstIndex(of: pattern)
                    ?? {
                        patterns.append(pattern)
                        return patterns.count - 1
                    }()
                arguments.append("pattern: _p\(index)")
            }
            return call("string", value: value, path: path, place: place, arguments: arguments, indent: indent)
        case .integer(let minimum, let exclusiveMinimum, let maximum, let exclusiveMaximum, let multipleOf):
            return call(
                "integer",
                value: value,
                path: path,
                place: place,
                arguments: boundArguments(minimum, exclusiveMinimum, maximum, exclusiveMaximum, multipleOf),
                indent: indent
            )
        case .number(let minimum, let exclusiveMinimum, let maximum, let exclusiveMaximum, let multipleOf):
            return call(
                "number",
                value: value,
                path: path,
                place: place,
                arguments: boundArguments(minimum, exclusiveMinimum, maximum, exclusiveMaximum, multipleOf),
                indent: indent
            )
        case .array(let minItems, let maxItems, let uniqueItems, let items):
            var arguments: [String] = []
            if let minItems { arguments.append("minItems: \(minItems)") }
            if let maxItems { arguments.append("maxItems: \(maxItems)") }
            if uniqueItems { arguments.append("uniqueItems: true") }
            // The element closure carries its own accumulator parameter rather than capturing the outer
            // one: the outer is `inout`, and a closure cannot capture that.
            let elementCheck =
                items.isEmpty
                ? nil
                : check(
                    value: "wireOpenAPIItem",
                    path: "\\(wireOpenAPIItemPath)",
                    location: location,
                    assertions: items,
                    indent: indent + "        ",
                    patterns: &patterns
                )
            guard let elementCheck, !elementCheck.isEmpty else {
                return call("array", value: value, path: path, place: place, arguments: arguments, indent: indent)
            }
            let body =
                elementCheck
                .replacingOccurrences(of: "into: &wireOpenAPIFailures", with: "into: &wireOpenAPIItemFailures")
                .replacingOccurrences(of: "at: \"\\(wireOpenAPIItemPath)\"", with: "at: wireOpenAPIItemPath")
            return """
                \(indent)WireOpenAPIValidate.array(
                \(indent)    \(value), at: "\(path)", in: \(place)\(arguments.isEmpty ? "" : ", " + arguments.joined(separator: ", ")),
                \(indent)    into: &wireOpenAPIFailures,
                \(indent)    element: { wireOpenAPIItem, wireOpenAPIItemPath, wireOpenAPIItemFailures in
                \(body)
                \(indent)    }
                \(indent))
                """
        }
    }

    private func boundArguments(
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
        value: String,
        path: String,
        place: String,
        arguments: [String],
        indent: String
    ) -> String {
        """
        \(indent)WireOpenAPIValidate.\(kind)(
        \(indent)    \(value), at: "\(path)", in: \(place)\(arguments.isEmpty ? "" : ", " + arguments.joined(separator: ", ")),
        \(indent)    into: &wireOpenAPIFailures
        \(indent))
        """
    }

    // MARK: - the call site

    /// The line the forwarder runs before handing the request to the controller, or nothing when this
    /// operation asserts nothing.
    func validationCall(_ operation: DiscoveredOperation, indent: String) -> String {
        guard !parameterAssertions(for: operation).isEmpty else { return "" }
        let member = GeneratorSafeNames.swiftMemberName(for: operation.operationID, strategy: namingStrategy)
        return "\(indent)try \(validationEnum).\(member)(input)\n"
    }
}

// MARK: - diagnostics

extension DirectDispatchEmitter {
    /// An assertion this adapter cannot check is a build error, not a silent omission.
    ///
    /// The rule is the one `diagnoseMappingForm` already applies to responses: where the document asks
    /// for something the adapter cannot construct, say so rather than quietly doing nothing. A document
    /// that declares `minLength` and gets no enforcement is the exact failure this whole capability
    /// exists to remove, so producing it *silently* would be worse than the gap it replaces.
    ///
    /// Two things are checked. A `pattern` is compiled here, at build time, so an expression Swift cannot
    /// read fails the build naming the parameter — rather than trapping in `WireOpenAPIPattern.init` on
    /// the first request that reaches it. And an assertion the reader marked unrepresentable (today: a
    /// string assertion on a `format: date-time`, which the generator emits as a `Foundation.Date`) is
    /// reported with the keywords that caused it.
    func diagnoseParameterAssertions() {
        for (_, entry) in byOperationID.sorted(by: { $0.key < $1.key }) {
            let operation = entry.operation
            for parameter in operationRoutes[operation.operationID]?.parameters ?? [] {
                diagnose(parameter.assertions, on: parameter, of: operation)
            }
        }
    }

    private func diagnose(
        _ assertions: SpecAssertions,
        on parameter: SpecParameter,
        of operation: DiscoveredOperation
    ) {
        switch assertions {
        case .none, .integer, .number:
            return
        case .array(_, _, _, let items):
            // The element assertions are the array's own concern, reported against the same parameter —
            // the author writes them in one place and should read about them in one place.
            diagnose(items, on: parameter, of: operation)
        case .unrepresentable(let keywords, let reason):
            fail(
                """
                the '\(parameter.name)' parameter of '\(operation.operationID)' declares \
                \(keywords.map { "`\($0)`" }.joined(separator: ", ")), which this adapter cannot check \
                because \(reason). Remove the assertion, or take the operation @RawOperation and check it \
                by hand.
                """,
                at: operation
            )
        case .string(_, _, let pattern):
            guard let pattern else { return }
            // Compiled with the same engine the runtime will use, so agreement is by construction rather
            // than by hope.
            guard (try? Regex(pattern)) == nil else { return }
            fail(
                """
                the '\(parameter.name)' parameter of '\(operation.operationID)' declares \
                `pattern: \(pattern)`, which Swift's regular-expression engine cannot compile. JSON \
                Schema patterns are ECMA-262; most translate directly, but this one does not. Rewrite it, \
                or remove it and check by hand.
                """,
                at: operation
            )
        }
    }
}
