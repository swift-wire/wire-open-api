import Foundation
import WireOpenAPINaming

// What an `@ErrorResponse` mapping has to satisfy to be emitted inside the forwarder.
//
// A mapping there answers *on behalf of the operation*: it returns the operation's own `Output`, so the
// response it produces has to be one the document describes. That is the whole of the rule, and both
// checks below follow from it — the status must be declared, and it must carry no body, because a
// status-only mapping has nothing to put in one.
//
// Terminal-scoped mappings are exempt and deliberately so. A `DecodingError` means the request never
// became this operation's `Input`, so the operation never began serving it and its documented responses
// do not describe the outcome.

extension DirectDispatchEmitter {
    /// An `@ErrorResponse` mapping has to name a status that exists, and produce a response the shim can
    /// build. A documented status carrying a *body* cannot be built from a bare status pair — there is
    /// nothing to put in it — so that is rejected rather than answered with an empty body the document
    /// promised would be full.
    func diagnoseErrorMappings() {
        for controller in controllers {
            for operation in controller.operations {
                // Terminal-scoped mappings answer for a request that never became this operation's
                // `Input`, so the operation's documented responses do not govern them and there is
                // nothing here to check them against.
                for mapping in operation.errorMappings where !mapping.isTerminalScoped {
                    guard (100...599).contains(statusCode(named: mapping.status)) else { continue }
                    if (100...599).first(where: {
                        GeneratorStatusNames.safeName(for: $0) == mapping.status
                    }) == nil {
                        fail(
                            """
                            @ErrorResponse(\(mapping.errorType).self, .\(mapping.status)) on \
                            '\(operation.operationID)' names a status this adapter cannot resolve. Use one \
                            of HTTPResponse.Status's named cases.
                            """,
                            at: operation
                        )
                    }
                    let documented = operationRoutes[operation.operationID]?.responses.first {
                        GeneratorStatusNames.safeName(for: $0.code) == mapping.status
                    }
                    // `.internalServerError` is exempt. wire-mvc already ends its chain with an implicit
                    // 500, and a document does not promise 500 the way it promises 404 — it is what
                    // happens when the promise cannot be kept.
                    if documented == nil, mapping.status == "internalServerError" { continue }
                    guard let documented else {
                        let declared = (operationRoutes[operation.operationID]?.responses ?? [])
                            .map { ".\(GeneratorStatusNames.safeName(for: $0.code))" }
                            .joined(separator: ", ")
                        fail(
                            """
                            @ErrorResponse(\(mapping.errorType).self, .\(mapping.status)) on \
                            '\(operation.operationID)' maps to a status the document does not declare for \
                            it. It declares \(declared.isEmpty ? "none" : declared). A mapped error is \
                            answered as one of the operation's own responses, so the document has to \
                            describe it — add it there, or map to one it already declares.
                            """,
                            at: operation
                        )
                    }
                    diagnoseMappingForm(operation, mapping, documented)
                }
            }
        }
    }

    /// The document picks the form. A response carrying no body can only be answered by the pair form —
    /// there is nothing to put in one — and a response that declares a body can only be answered by the
    /// three-argument form, because a bare case cannot construct what the schema promises.
    private func diagnoseMappingForm(
        _ operation: DiscoveredOperation,
        _ mapping: ErrorMapping,
        _ documented: SpecResponse
    ) {
        if documented.contentTypes.isEmpty, mapping.bodyClosure != nil {
            fail(
                """
                @ErrorResponse(\(mapping.errorType).self, .\(mapping.status), …) on \
                '\(operation.operationID)' supplies a body, but the document's \(documented.code) response \
                carries none. Drop the closure.
                """,
                at: operation
            )
        }
        if !documented.contentTypes.isEmpty, mapping.bodyClosure == nil {
            fail(
                """
                @ErrorResponse(\(mapping.errorType).self, .\(mapping.status)) on \
                '\(operation.operationID)' maps to a \(documented.code) response that carries a body, so a \
                status alone cannot construct it. Supply one — \
                @ErrorResponse(\(mapping.errorType).self, .\(mapping.status), { e in … }).
                """,
                at: operation
            )
        }
        // A body it can construct is a JSON one; anything else, or a choice of several, is out of reach.
        guard
            documented.contentTypes.count > 1
                || documented.contentTypes.first.map({ $0 != "application/json" }) == true
        else { return }
        fail(
            """
            @ErrorResponse(\(mapping.errorType).self, .\(mapping.status)) on \
            '\(operation.operationID)' maps to a \(documented.code) response whose content type this \
            adapter cannot construct — it builds JSON bodies only. Use @RawOperation for this operation.
            """,
            at: operation
        )
    }

    /// A catch-all matches everything, so any mapping after it can never run — the same rule wire-mvc
    /// applies within a scope, extended across them because route-scope mappings fold inside
    /// controller-scope ones. Dead mappings are worth naming: nothing else would ever tell the author.
    ///
    /// It also keeps the placement rule sound. A catch-all is matched at the terminal as well as in the
    /// forwarder, and if something could follow it there, the two sites would disagree about which
    /// mapping wins.
    func diagnoseCatchAllOrdering() {
        for controller in controllers {
            for operation in controller.operations {
                let ordered = operation.errorMappings + controller.errorMappings
                guard let index = ordered.firstIndex(where: { $0.isCatchAll }) else { continue }
                var seen: Set<String> = []
                let shadowed = ordered.dropFirst(index + 1)
                    .map(\.errorType)
                    .filter { seen.insert($0).inserted }
                guard !shadowed.isEmpty else { continue }
                fail(
                    """
                    @ErrorResponse(\(ordered[index].errorType).self, .\(ordered[index].status)) on \
                    '\(operation.operationID)' is a catch-all, so the mappings after it can never match — \
                    \(shadowed.joined(separator: ", ")). Put the catch-all last.
                    """,
                    at: operation,
                    in: controller
                )
            }
        }
    }

    /// A controller-scope mapping covers every operation the controller declares, so an undeclared status
    /// is one problem with many instances — reported once, against the controller, naming the operations
    /// that would need it. Reporting it per operation would say "on 'summariseTask'" about a mapping the
    /// author wrote on the type, five times over.
    func diagnoseControllerErrorMappings() {
        for controller in controllers {
            for mapping in controller.errorMappings where !mapping.isTerminalScoped {
                let undeclared = controller.operations
                    .filter { operation in
                        // A route-scope mapping for the same error shadows this one, so that operation is
                        // not covered by it and needs nothing declared.
                        guard !operation.errorMappings.contains(where: { $0.errorType == mapping.errorType })
                        else { return false }
                        let responses = operationRoutes[operation.operationID]?.responses ?? []
                        return !responses.contains {
                            GeneratorStatusNames.safeName(for: $0.code) == mapping.status
                        }
                    }
                    .map { "'\($0.operationID)'" }
                    .sorted()
                guard !undeclared.isEmpty else { continue }
                fail(
                    """
                    @ErrorResponse(\(mapping.errorType).self, .\(mapping.status)) on \
                    '\(controller.typeName)' maps to a status the document does not declare for \
                    \(undeclared.joined(separator: ", ")). A mapped error is answered as one of the \
                    operation's own responses, so every operation the mapping covers has to declare \
                    \(statusCode(named: mapping.status)) — add it there, or move the mapping to the \
                    operations that do.
                    """,
                    in: controller
                )
            }
        }
    }
}
