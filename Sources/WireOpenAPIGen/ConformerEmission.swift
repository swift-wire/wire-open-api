import Foundation

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
    private func forwarder(_ controller: DiscoveredController, _ operation: DiscoveredOperation) -> String {
        let signature =
            "    func \(operation.methodName)(_ input: \(operation.inputType)) async throws "
            + "-> \(operation.outputType) {"
        // App-scoped: a stored field, populated once when the template is built.
        guard controller.seed != nil else {
            return """
                \(signature)
                        try await \(conformerField(controller)).\(operation.methodName)(input)
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
                    return try await wireOpenAPISubject.\(operation.methodName)(input)
                }
            """
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
