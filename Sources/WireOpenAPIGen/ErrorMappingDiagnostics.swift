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
    /// The response this mapping names, when the operation's document declares it.
    ///
    /// One lookup rather than four copies of the same `first(where:)`: which response a mapping refers to
    /// is the question every check below starts from, and three spellings of it is how they drifted apart.
    func documentedResponse(_ mapping: ErrorMapping, for operation: DiscoveredOperation) -> SpecResponse? {
        operationRoutes[operation.operationID]?.responses.first {
            GeneratorStatusNames.safeName(for: $0.code) == mapping.status
        }
    }

    /// Whether the shim can build this response's body at all — one content type, and JSON. A response
    /// carrying none is constructible: there is simply nothing to put in it.
    func canConstruct(_ documented: SpecResponse) -> Bool {
        documented.contentTypes.count <= 1
            && documented.contentTypes.first.map { $0 == "application/json" } != false
    }

    /// An `@ErrorResponse` mapping has to name a status that exists, and produce a response the shim can
    /// build. A documented status carrying a *body* cannot be built from a bare status pair — there is
    /// nothing to put in it — so that is rejected rather than answered with an empty body the document
    /// promised would be full.
    func diagnoseErrorMappings() {
        for controller in controllers {
            for operation in controller.operations {
                for mapping in operation.errorMappings {
                    // Terminal-scoped mappings answer for a request that never became this operation's
                    // `Input`, so the document's responses do not govern *whether* they may name a
                    // status — that is the exemption, and it stands.
                    //
                    // It does not extend to the mapping's **form**. `errorCatches` still emits a clause
                    // for one inside the forwarder when the document declares the status, and that
                    // clause constructs a response like any other. Exempting the whole mapping is what
                    // let a pair-form `@ErrorResponse(DecodingError.self, .notFound)` emit
                    // `.notFound(.init())` against a 404 carrying a body — a compile error inside
                    // generated code, at a line nobody wrote.
                    guard !mapping.isTerminalScoped else {
                        if let documented = documentedResponse(mapping, for: operation) {
                            diagnoseMappingForm(operation, mapping, documented)
                        }
                        continue
                    }
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
                    let documented = documentedResponse(mapping, for: operation)
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
        guard !canConstruct(documented) else { return }
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
            for mapping in controller.errorMappings {
                // The operations this mapping actually covers. A route-scope mapping for the same error
                // shadows it, so that operation is not its concern.
                let covered = controller.operations.filter { operation in
                    !operation.errorMappings.contains { $0.errorType == mapping.errorType }
                }
                if !mapping.isTerminalScoped {
                    let undeclared =
                        covered
                        .filter { documentedResponse(mapping, for: $0) == nil }
                        .map { "'\($0.operationID)'" }
                        .sorted()
                    if !undeclared.isEmpty {
                        fail(
                            """
                            @ErrorResponse(\(mapping.errorType).self, .\(mapping.status)) on \
                            '\(controller.typeName)' maps to a status the document does not declare for \
                            \(undeclared.joined(separator: ", ")). A mapped error is answered as one of \
                            the operation's own responses, so every operation the mapping covers has to \
                            declare \(statusCode(named: mapping.status)) — add it there, or move the \
                            mapping to the operations that do.
                            """,
                            in: controller
                        )
                    }
                }
                diagnoseControllerMappingForm(controller, mapping, covered: covered)
            }
        }
    }

    /// The form check for a **controller-scope** mapping.
    ///
    /// Route scope asks this of one response; controller scope asks it of every operation the mapping
    /// covers, which is why it cannot reuse `diagnoseMappingForm` — and why it carries a failure route
    /// scope cannot have. Two operations may each declare the status and disagree about whether it
    /// carries a body, and then *no* form works: the mapping is asked to construct a bare case for one
    /// and a value for the other. Naming that as its own problem matters, because its fix is different
    /// from choosing the other form.
    ///
    /// Reported once against the controller, naming the operations. Per operation it would say "on
    /// 'summariseTask'" about a mapping the author wrote on the type, once for each.
    private func diagnoseControllerMappingForm(
        _ controller: DiscoveredController,
        _ mapping: ErrorMapping,
        covered: [DiscoveredOperation]
    ) {
        // Only an operation whose document declares the status gets a clause built from this mapping.
        // The rest are answered at the terminal, or have already been reported above.
        let declaring = covered.compactMap { operation in
            documentedResponse(mapping, for: operation).map { (operation: operation, response: $0) }
        }
        guard !declaring.isEmpty else { return }
        let named = { (rows: [(operation: DiscoveredOperation, response: SpecResponse)]) in
            rows.map { "'\($0.operation.operationID)'" }.sorted().joined(separator: ", ")
        }

        // Reported before the pair/closure question, deliberately: a response this adapter cannot build
        // at all has no right answer to that question, and asking it would send the author to change the
        // wrong thing.
        let unconstructible = declaring.filter { !canConstruct($0.response) }
        if !unconstructible.isEmpty {
            fail(
                """
                @ErrorResponse(\(mapping.errorType).self, .\(mapping.status)) on \
                '\(controller.typeName)' maps to a response whose content type this adapter cannot \
                construct for \(named(unconstructible)) — it builds JSON bodies only. Use @RawOperation \
                for those operations.
                """,
                in: controller
            )
        }

        let withBody = declaring.filter { !$0.response.contentTypes.isEmpty }
        let withoutBody = declaring.filter { $0.response.contentTypes.isEmpty }

        // The covered operations disagree, so one mapping at this scope cannot serve them.
        if !withBody.isEmpty, !withoutBody.isEmpty {
            fail(
                """
                @ErrorResponse(\(mapping.errorType).self, .\(mapping.status)) on \
                '\(controller.typeName)' covers operations whose \(statusCode(named: mapping.status)) \
                responses disagree about carrying a body — with: \(named(withBody)); without: \
                \(named(withoutBody)). One mapping cannot construct both — move it to route scope on \
                each, or make the document agree.
                """,
                in: controller
            )
        }
        if mapping.bodyClosure != nil, !withoutBody.isEmpty {
            fail(
                """
                @ErrorResponse(\(mapping.errorType).self, .\(mapping.status), …) on \
                '\(controller.typeName)' supplies a body, but the document's \
                \(statusCode(named: mapping.status)) response carries none for \(named(withoutBody)). \
                Drop the closure.
                """,
                in: controller
            )
        }
        if mapping.bodyClosure == nil, !withBody.isEmpty {
            fail(
                """
                @ErrorResponse(\(mapping.errorType).self, .\(mapping.status)) on \
                '\(controller.typeName)' maps to a \(statusCode(named: mapping.status)) response that \
                carries a body for \(named(withBody)), so a status alone cannot construct it. Supply \
                one — @ErrorResponse(\(mapping.errorType).self, .\(mapping.status), { e in … }).
                """,
                in: controller
            )
        }
    }
}
