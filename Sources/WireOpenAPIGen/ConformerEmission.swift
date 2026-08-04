import Foundation
import WireOpenAPINaming

// The conformer half of a spec's emission: the type an operation is actually called through, and the
// namespace that keeps two documents' identically-spelled generated types apart.

extension DirectDispatchEmitter {
    /// The conformer an operation is called through. With a request-scoped controller in the group it is
    /// built per request; with none, the aggregate itself, which already holds every subject.
    ///
    /// Request-scoped fields are optional for two reasons: the server has to be built before any request
    /// exists, and a request enters only the scope of the controller owning the operation it dispatches —
    /// entering all of them would construct subjects the request never uses, which is the waste
    /// per-root reachability exists to avoid. So the other fields are legitimately `nil` and simply never
    /// read; reaching one means generated code was bypassed, which is a programming error here rather
    /// than anything a caller can cause.
    func conformerDeclaration() -> String {
        let forwarders = controllers.flatMap { controller in
            controller.operations.map { forwarder(controller, $0) }
        }
        let fields = controllers.map { controller in
            "    let \(conformerField(controller)): \(controller.typeName)"
                + (controller.seed != nil ? "?" : "")
        }
        let body = """
            struct Conformer: APIProtocol {
            \(fields.joined(separator: "\n"))

            \(forwarders.joined(separator: "\n\n"))
            }
            """
        // The aliases are what make the forwarders' verbatim types resolve to this spec's module. They
        // are omitted when the spec is this target's own: `typealias Operations = Operations` is circular,
        // and nothing needs disambiguating — a module's own declarations already win over imports.
        let aliases =
            specModule == nil
            ? ""
            : ["APIProtocol", "Components", "Operations", "Servers"]
                .map { "    typealias \($0) = \(qualified($0))\n" }
                .joined() + "\n"
        return """
            enum \(namespace) {
            \(aliases)\(indented(body))
            }
            """
    }

    /// Shift a block one nesting level in, for embedding in the namespace.
    private func indented(_ block: String) -> String {
        block.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "    " + $0 }
            .joined(separator: "\n")
    }

    /// One operation, forwarded to the controller that declared it.
    ///
    /// The conformer implements the *generated* requirement, whose name comes from the operationId
    /// through the safe-name transform — not from the author's method name, which they are free to
    /// choose. For `getTask` the two coincide; for `@RawOperation("get-task")` under the defensive
    /// strategy they do not.
    private func forwarder(_ controller: DiscoveredController, _ operation: DiscoveredOperation) -> String {
        let requirement = GeneratorSafeNames.swiftMemberName(for: operation.operationID, strategy: namingStrategy)
        let inputType = operation.inputType ?? "\(operationNamespace(operation)).Input"
        let outputType = operation.outputType ?? "\(operationNamespace(operation)).Output"
        let signature =
            "    func \(requirement)(_ input: \(inputType)) async throws "
            + "-> \(outputType) {"
        let body = callAndReturn(operation, subject: "wireOpenAPISubject", indent: "            ")
        let catches = errorCatches(controller, operation, indent: "        ")
        /// The call, wrapped in the operation's mappings when it has any. An unmapped error propagates,
        /// which leaves it to the runtime's tier — the behaviour before any mapping existed.
        func guarded(_ call: String) -> String {
            guard !catches.isEmpty else { return call }
            return """
                        do {
                \(call)
                \(catches)
                        }
                """
        }
        // App-scoped: a stored field, populated once when the template is built.
        guard controller.seed != nil else {
            return """
                \(signature)
                \(guarded(callAndReturn(operation, subject: conformerField(controller), indent: "            ")))
                    }
                """
        }
        return """
            \(signature)
                    guard let wireOpenAPISubject = \(conformerField(controller)) else {
                        preconditionFailure(
                            "WireOpenAPI: '\(operation.operationID)' was dispatched with no "
                                + "request-scoped subject bound. The route terminal binds one "
                                + "before every call."
                        )
                    }
            \(guarded(body))
                }
            """
    }

    /// `Operations.<X>` for an operation, spelled as this spec's namespace resolves it.
    private func operationNamespace(_ operation: DiscoveredOperation) -> String {
        "Operations.\(GeneratorSafeNames.swiftTypeName(for: operation.operationID, strategy: namingStrategy))"
    }

    /// The `@ErrorResponse` catch clauses for an operation, route-scope first.
    ///
    /// They live in the *forwarder* rather than the route terminal, because a mapping has to produce the
    /// operation's `Output`: the generator then serialises it exactly as it would a success, so a mapped
    /// error is answered with a response the document describes. Ordering is WireMVC's — route-inner
    /// before controller-outer, first match wins.
    ///
    /// What this does **not** cover is a failure the generator's own machinery raised before the handler
    /// ran — a malformed body, a path parameter of the wrong type. Those are thrown inside
    /// `UniversalServer.handle`, outside this `do`, and keep the runtime's own mapping. So `@ErrorResponse`
    /// governs what a *handler* threw, which is what it governs in WireMVC too.
    func errorCatches(
        _ controller: DiscoveredController,
        _ operation: DiscoveredOperation,
        indent: String
    ) -> String {
        // Route-inner before controller-outer, and only the first mapping for a given error type: a
        // shadowed one would emit an unreachable `catch`, which Swift accepts silently. Dropping it makes
        // first-match-wins visible in the output instead of implied by clause order.
        var seen: Set<String> = []
        let mappings = (operation.errorMappings + controller.errorMappings).filter {
            seen.insert($0.errorType).inserted
        }
        guard !mappings.isEmpty else { return "" }
        return mappings.map { mapping in
            """
            \(indent)} catch is \(mapping.errorType) {
            \(indent)    return \(errorOutcome(mapping, for: operation))
            """
        }
        .joined(separator: "\n")
    }

    /// What a mapped error returns: the document's own response case when it declares that status and it
    /// carries no body, and `.undocumented(statusCode:)` otherwise — the generated escape for a status
    /// the document does not describe.
    private func errorOutcome(_ mapping: ErrorMapping, for operation: DiscoveredOperation) -> String {
        let responses = operationRoutes[operation.operationID]?.responses ?? []
        let documented = responses.first {
            GeneratorStatusNames.safeName(for: $0.code) == mapping.status
        }
        guard let documented, documented.contentTypes.isEmpty else {
            let code = documented?.code ?? statusCode(named: mapping.status)
            return ".undocumented(statusCode: \(code), .init())"
        }
        return ".\(GeneratorStatusNames.safeName(for: documented.code))(.init())"
    }

    /// The numeric status a written name refers to, found by inverting the generator's own table — the
    /// same table that named it. Falls back to 500, which `diagnoseErrorMappings` has already rejected.
    func statusCode(named written: String) -> Int {
        (100...599).first { GeneratorStatusNames.safeName(for: $0) == written } ?? 500
    }

    /// The call into the controller, and what to do with what comes back.
    ///
    /// Raw: the `Input` goes straight through. Typed: each parameter is read from the `Input` member the
    /// document says it lives in, and the return value is wrapped in the operation's response — which is
    /// the decomposition the shim exists to perform.
    private func callAndReturn(
        _ operation: DiscoveredOperation,
        subject: String,
        indent: String = "        "
    ) -> String {
        guard operation.isTyped else {
            return "\(indent)return try await \(subject).\(operation.methodName)(input)"
        }
        let arguments = operation.parameters.map { parameter -> String in
            let label = parameter.label.map { "\($0): " } ?? ""
            // The body is unwrapped into a local first; everything else is read inline.
            guard !parameter.isBody else { return "\(label)wireOpenAPIBody" }
            return "\(label)input.\(inputMember(for: parameter, in: operation))"
        }
        let prelude =
            operation.parameters.first(where: \.isBody)
            .map { bodyBinding($0, in: operation, indent: indent) + "\n" } ?? ""
        let call = "try await \(subject).\(operation.methodName)(\(arguments.joined(separator: ", ")))"
        let response = selectedResponse(for: operation)
        let caseName = GeneratorStatusNames.safeName(for: response.code)
        guard operation.returnType != nil else {
            // A documented no-content response: nothing to carry, so the call stands alone.
            return """
                \(prelude)\(indent)\(call)
                \(indent)return .\(caseName)(.init())
                """
        }
        return """
            \(prelude)\(indent)let wireOpenAPIResult = \(call)
            \(indent)return .\(caseName)(.init(body: .json(wireOpenAPIResult)))
            """
    }

    /// Which of the document's responses this handler constructs.
    ///
    /// The document decides, as it does for parameters. One documented success needs no saying; several
    /// are ambiguous and the handler has to name one with `@JSONResponse(status:)`. Both cases are
    /// diagnosed in `diagnoseTypedResponses`, so this only has to agree with it.
    func selectedResponse(for operation: DiscoveredOperation) -> SpecResponse {
        let responses = operationRoutes[operation.operationID]?.responses ?? []
        if let written = operation.responseStatus,
            let named = responses.first(where: {
                GeneratorStatusNames.safeName(for: $0.code) == written
            })
        {
            return named
        }
        return responses.first { (200..<300).contains($0.code) }
            ?? SpecResponse(code: 200, contentTypes: ["application/json"])
    }

    /// Unwrapping the request body out of the generated `Input.Body` enum.
    ///
    /// The enum has one case per documented content type, so a JSON-only body gives a single-case switch
    /// — exhaustive without a `default`, which means adding a content type to the document turns into a
    /// compile error here rather than a silently unhandled case.
    private func bodyBinding(
        _ parameter: BoundParameter,
        in operation: DiscoveredOperation,
        indent: String
    ) -> String {
        let type = parameter.type
        guard type.hasSuffix("?") else {
            return """
                \(indent)let wireOpenAPIBody: \(type)
                \(indent)switch input.body {
                \(indent)case .json(let wireOpenAPIValue): wireOpenAPIBody = wireOpenAPIValue
                \(indent)}
                """
        }
        return """
            \(indent)let wireOpenAPIBody: \(type)
            \(indent)switch input.body {
            \(indent)case .some(.json(let wireOpenAPIValue)): wireOpenAPIBody = wireOpenAPIValue
            \(indent)case .none: wireOpenAPIBody = nil
            \(indent)}
            """
    }

    /// `path.id` / `query.includeDone` / `headers.xRequestId` — the location from the *document*, the
    /// member spelling from the transform.
    private func inputMember(for parameter: BoundParameter, in operation: DiscoveredOperation) -> String {
        let member = GeneratorSafeNames.swiftMemberName(for: parameter.documentedName, strategy: namingStrategy)
        let location = operationRoutes[operation.operationID]?
            .parameters
            .first { $0.name == parameter.documentedName }?
            .location
        // `diagnoseTypedBindings` has already rejected a name the document does not declare and a
        // location it contradicts, so this fallback is unreachable; it keeps emission total.
        let fallback: SpecParameter.Location =
            parameter.binding == "Path"
            ? .path
            : parameter.binding == "Query" ? .query : .header
        return "\((location ?? fallback).inputMember).\(member)"
    }

    /// A conformer literal. `binding` names the controller whose subject is held in `wireOpenAPISubject`
    /// for this request; every other request-scoped field is `nil`, and app-scoped ones come from the
    /// proxy. Passing `nil` gives the template built at registration.
    func conformerLiteral(binding: DiscoveredController?, indent: String) -> String {
        let arguments = controllers.map { controller -> String in
            let value: String
            if controller.seed == nil {
                value = "self.\(proxySubjectField(controller))"
            } else if controller.typeName == binding?.typeName {
                value = "wireOpenAPISubject"
            } else {
                value = "nil"
            }
            return "\(indent)    \(conformerField(controller)): \(value)"
        }
        return "\(conformer)(\n\(arguments.joined(separator: ",\n"))\n\(indent))"
    }
}
