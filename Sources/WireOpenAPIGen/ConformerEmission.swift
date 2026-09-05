// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-open-api project authors

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
        let fields =
            controllers.enumerated().map { index, controller in
                "    let \(conformerField(controller)): \(controller.subjectType(prefix: DiscoveredController.genericPrefix(index)))"
                    + (controller.seed != nil ? "?" : "")
            } + scopeResolvedFields
        rejectGenericWhereClauses()
        let body = """
            struct Conformer\(conformerGenericClause): APIProtocol {
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
        let noSubject = noSubjectHelper
        // Inside the namespace, so the validator's `Operations.X.Input` resolves to *this* spec's module
        // by the same typealiases the forwarders rely on.
        let validation = validationDeclaration().map { "\n" + indented($0) + "\n" } ?? ""
        return """
            enum \(namespace) {
            \(aliases)\(indented(body))\(validation)\(indented(noSubject))
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

    /// The local a graph-aware parameter is bound into, before the handler call.
    private func scopeResolvedLocal(_ parameter: BoundParameter) -> String {
        "wireOpenAPIResolved_\(parameter.name)"
    }

    /// One `let` per graph-aware parameter, calling the worker the wrapper named.
    ///
    /// The `guard` is the same shape the request-scoped subject's is, and unreachable for the same reason:
    /// only a per-request rebuild dispatches, and it fills every one of these. `name:` is the attribute's
    /// argument — the *action* — which is what a worker keys its decision on.
    private func scopeResolvedBinds(_ operation: DiscoveredOperation, indent: String) -> String {
        let binds = operation.parameters.filter(\.isScopeResolved).compactMap { parameter -> String? in
            guard let worker = parameter.worker else { return nil }
            return """
                \(indent)guard let \(scopeResolvedLocal(parameter))Worker = \(workerField(worker)),
                \(indent)    let wireOpenAPIBoundRequest = \(scopeResolvedRequestField),
                \(indent)    let wireOpenAPIBoundPath = \(scopeResolvedPathParametersField)
                \(indent)else {
                \(indent)    preconditionFailure(
                \(indent)        "WireOpenAPI: '\(operation.operationID)' was dispatched with no "
                \(indent)            + "request-scoped '\(worker)' bound. The route terminal binds one "
                \(indent)            + "before every call."
                \(indent)    )
                \(indent)}
                \(indent)let \(scopeResolvedLocal(parameter)) = try await \(scopeResolvedLocal(parameter))Worker.bind(
                \(indent)    name: "\(parameter.documentedName)", request: wireOpenAPIBoundRequest,
                \(indent)    pathParameters: wireOpenAPIBoundPath, body: nil
                \(indent))
                """
        }
        return binds.isEmpty ? "" : binds.joined(separator: "\n") + "\n"
    }

    /// Every distinct worker a graph-aware parameter in this group names, sorted so the emitted file is
    /// stable, plus the request and matched path parameters its `bind` takes.
    ///
    /// Spec-wide, because the conformer is: one type implements the whole document, so it carries a field
    /// for every worker any of its operations needs. Which of those fields a given rebuild can *fill* is a
    /// different question — see ``scopeResolvedWorkers(of:)``.
    var scopeResolvedWorkers: [String] {
        Set(
            controllers.flatMap(\.operations).flatMap(\.parameters).compactMap(\.worker)
        ).sorted()
    }

    /// The workers **one controller's** operations name — the ones its own scope entry yields.
    ///
    /// A rebuild enters exactly one scope, and swift-wire yields on that entry only what the parameters of
    /// that controller's methods asked for. Filling every spec-wide field from it therefore names members
    /// the entry does not have, which is a compile error in emitted code and needs a second scoped
    /// controller in one document to reach: with one, the two sets are equal and nothing is wrong.
    func scopeResolvedWorkers(of controller: DiscoveredController) -> Set<String> {
        Set(controller.operations.flatMap(\.parameters).compactMap(\.worker))
    }

    /// The conformer fields a graph-aware parameter needs.
    ///
    /// All optional, for the reason the request-scoped subjects are: the *template* conformer is built
    /// once at registration with nothing bound, and only a per-request rebuild has a scope entry to fill
    /// these from. Reaching one on the template means generated code was bypassed.
    ///
    /// The request and the matched path parameters come along because the worker's `bind` takes them and
    /// a forwarder has neither — its argument is the decoded `Input`. Binding out in the route terminal
    /// instead would put the call outside the `catch` clauses `@ErrorResponse` emits here, so a refusal
    /// the author mapped would escape every mapping they wrote.
    private var scopeResolvedFields: [String] {
        let workers = scopeResolvedWorkers
        guard !workers.isEmpty else { return [] }
        return workers.map { "    let \(workerField($0)): \($0)?" }
            + [
                "    let \(scopeResolvedRequestField): HTTPRequest?",
                "    let \(scopeResolvedPathParametersField): [String: Substring]?",
            ]
    }

    /// `Operations.<X>` for an operation, spelled as this spec's namespace resolves it.
    func operationNamespace(_ operation: DiscoveredOperation) -> String {
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
        // Terminal-scoped types can be thrown by the handler too — a `DecodingError` from decoding
        // something by hand, and a catch-all by definition — so they are emitted here as well, and get
        // the document's own response case. Only when the document declares that status, though: the
        // point of those mappings is breadth, and requiring every covered operation to declare the
        // status would tax exactly the mappings meant to be broad. The terminal copy answers the rest,
        // with the same status and the same body, so nothing is lost by skipping this one.
        let mappings = (operation.errorMappings + controller.errorMappings)
            .filter { seen.insert($0.errorType).inserted }
            .filter { !$0.isTerminalScoped || declaresStatus($0, for: operation) }
        guard !mappings.isEmpty else { return "" }
        // First, and ahead of every author mapping: a *response* validation failure must not be matched
        // by the clauses of the `do` it was thrown from. Without this a `Swift.Error` catch-all would
        // answer the service's own breach as though the caller had caused it, and an `@ErrorResponse` on
        // the response error whose own body is invalid would loop. Rethrowing here sends it one hop to
        // the terminal, where `HTTPResponseConvertible` answers 500 with no body of the document's.
        let regress =
            settings.validatesResponses
            ? """
            \(indent)} catch let wireOpenAPIResponseFailure as WireOpenAPIResponseValidationError {
            \(indent)    throw wireOpenAPIResponseFailure
            """ + "\n"
            : ""
        return regress
            + mappings.map { mapping in
                let pattern =
                    mapping.bodyClosure == nil
                    ? "catch is \(mapping.errorType)"
                    : "catch let wireOpenAPIError as \(mapping.errorType)"
                return """
                    \(indent)} \(pattern) {
                    \(mappedOutcome(mapping, for: operation, indent: indent + "    "))
                    """
            }
            .joined(separator: "\n")
    }

    /// What a mapped error returns: the document's own response case when it declares that status and it
    /// carries no body, and `.undocumented(statusCode:)` otherwise — the generated escape for a status
    /// the document does not describe.
    /// What a mapped error returns: the document's own response case.
    ///
    /// No `.undocumented` fallback any more. A mapping emitted inside the forwarder answers *on behalf of
    /// the operation*, so `diagnoseErrorMappings` requires it to name a status the document declares and
    /// that carries no body — which leaves exactly one thing to construct.
    private func errorOutcome(_ mapping: ErrorMapping, for operation: DiscoveredOperation) -> String {
        let documented = operationRoutes[operation.operationID]?.responses.first {
            GeneratorStatusNames.safeName(for: $0.code) == mapping.status
        }
        let code = documented?.code ?? statusCode(named: mapping.status)
        let caseName = GeneratorStatusNames.safeName(for: code)
        // One form per shape, and the document picks: a response carrying no body can only be a bare
        // case, one carrying a body can only be built from a value. `diagnoseErrorMappings` has already
        // rejected the mismatch, so there is nothing to decide here.
        guard let body = mapping.bodyClosure else { return ".\(caseName)(.init())" }
        return ".\(caseName)(.init(body: .json(try wireOpenAPIErrorBody(wireOpenAPIError, \(body)))))"
    }

    /// Whether the document declares this mapping's status for the operation.
    func declaresStatus(_ mapping: ErrorMapping, for operation: DiscoveredOperation) -> Bool {
        (operationRoutes[operation.operationID]?.responses ?? [])
            .contains { GeneratorStatusNames.safeName(for: $0.code) == mapping.status }
    }

    /// The `rejectionResponse:` closure the terminal consults — the mappings that can only be matched out
    /// there, in the order they were written.
    ///
    /// A request that failed to decode never became this operation's `Input`, so the operation's
    /// documented responses do not describe it, which is why these statuses are echoed as written rather
    /// than resolved against the document.
    func terminalRejectionClosure(
        _ controller: DiscoveredController,
        _ operation: DiscoveredOperation,
        indent: String
    ) -> String? {
        rejectionClosure(
            (operation.errorMappings + controller.errorMappings).filter(\.arrivesAtTerminal),
            opening: "rejectionResponse: { wireOpenAPIRejection in",
            closing: "},",
            indent: indent
        )
    }

    /// The closure that answers a failure entering the **request scope** — the mappings written on the
    /// controller, matched one level outside the forwarder that would normally have had them.
    ///
    /// Controller-scope only, and the narrowing is the design rather than a shortcut. One scope entry
    /// serves every operation the controller implements, so a failure entering it is not attributable to
    /// any one of them, and a mapping written on a single `@Operation` was describing that operation's
    /// handler. `diagnoseControllerErrorMappings` already refuses a controller-scope mapping whose status
    /// some operation does not declare, which is precisely the condition that makes this answer one the
    /// document describes whichever operation was asked for.
    ///
    /// `nil` when the controller wrote none, and the terminal then emits its original straight-line shape:
    /// there is nothing to answer with, so nothing is gained by routing the throw through a branch.
    func scopeEntryRejectionClosure(_ controller: DiscoveredController, indent: String) -> String? {
        rejectionClosure(
            controller.errorMappings,
            opening: "mapped: { wireOpenAPIRejection in",
            closing: "},",
            indent: indent
        )
    }

    /// The shared body of both: a `(any Error) -> (HTTPResponse, HTTPBody?)?` written out as clauses in
    /// the order the author wrote the mappings, first match wins, `nil` for no match.
    ///
    /// A `ServerError` is unwrapped first: the runtime puts the real cause in its public
    /// `underlyingError`, which for a body it could not parse is a `DecodingError`. Statuses are echoed as
    /// the author wrote them, because out here the response is assembled directly rather than being one of
    /// the document's cases.
    private func rejectionClosure(
        _ candidates: [ErrorMapping],
        opening: String,
        closing: String,
        indent: String
    ) -> String? {
        var seen: Set<String> = []
        let mappings = candidates.filter { seen.insert($0.errorType).inserted }
        guard !mappings.isEmpty else { return nil }
        let clauses = mappings.map { mapping -> String in
            let isCatchAll = ["Error", "Swift.Error"].contains(mapping.errorType)
            // The body form encodes here rather than going through the generator's serializer, which is
            // out of reach: this request never became an `Input`. An encoding failure falls through to the
            // next tier rather than being swallowed — a payload that will not encode is a programming
            // error, and 500 is the honest answer to it.
            guard let body = mapping.bodyClosure else {
                let outcome = "(HTTPResponse(status: .\(mapping.status)), nil)"
                guard !isCatchAll else { return "\(indent)    return \(outcome)" }
                return """
                    \(indent)    if wireOpenAPICause is \(mapping.errorType) {
                    \(indent)        return \(outcome)
                    \(indent)    }
                    """
            }
            let encoded = """
                \(indent)        if let wireOpenAPIData = try? JSONEncoder().encode(\(body)(wireOpenAPITyped)) {
                \(indent)            return (
                \(indent)                HTTPResponse(
                \(indent)                    status: .\(mapping.status),
                \(indent)                    headerFields: [.contentType: "application/json"]
                \(indent)                ),
                \(indent)                HTTPBody([UInt8](wireOpenAPIData))
                \(indent)            )
                \(indent)        }
                """
            guard !isCatchAll else {
                return """
                    \(indent)    do {
                    \(indent)        let wireOpenAPITyped = wireOpenAPICause
                    \(encoded)
                    \(indent)    }
                    """
            }
            return """
                \(indent)    if let wireOpenAPITyped = wireOpenAPICause as? \(mapping.errorType) {
                \(encoded)
                \(indent)    }
                """
        }
        return """
            \(indent)\(opening)
            \(indent)    let wireOpenAPICause =
            \(indent)        (wireOpenAPIRejection as? ServerError)?.underlyingError ?? wireOpenAPIRejection
            \(clauses.joined(separator: "\n"))
            \(indent)    return nil
            \(indent)\(closing)
            """
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
        // Before anything else, and inside the `do`: a validation failure is an outcome of *this*
        // operation, so `@ErrorResponse` gets its turn at it exactly as it does at a handler throw.
        let validation = validationCall(operation, indent: indent)
        guard operation.isTyped else {
            // A raw handler builds its own `Output`, so checking what it returns means destructuring the
            // value back out — bound to a local only when there is something to check.
            let rawChecks = rawResponseChecks(operation, indent: indent)
            guard !rawChecks.isEmpty else {
                return "\(validation)\(indent)return try await \(subject).\(operation.methodName)(input)"
            }
            return """
                \(validation)\(indent)let wireOpenAPIOutput = try await \(subject).\(operation.methodName)(input)
                \(rawChecks)
                \(indent)return wireOpenAPIOutput
                """
        }
        // A graph-aware parameter is bound before the call, in this frame, so a refusal it throws lands
        // inside the `do` the `@ErrorResponse` catches wrap — the same turn a handler throw gets.
        let resolved = scopeResolvedBinds(operation, indent: indent)
        let arguments = operation.parameters.map { parameter -> String in
            let label = parameter.label.map { "\($0): " } ?? ""
            // The body is unwrapped into a local first; everything else is read inline.
            guard !parameter.isBody else { return "\(label)wireOpenAPIBody" }
            // Bound above rather than projected: what it produced never crossed the wire, so `Input` has
            // no member for it.
            guard !parameter.isScopeResolved else { return "\(label)\(scopeResolvedLocal(parameter))" }
            return "\(label)input.\(inputMember(for: parameter, in: operation))"
        }
        let prelude =
            validation
            + (operation.parameters.first(where: \.isBody)
                .map { bodyBinding($0, in: operation, indent: indent) + "\n" } ?? "")
            + resolved
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
            \(typedResponseCheck(operation, indent: indent))\(indent)return .\(caseName)(.init(body: .json(wireOpenAPIResult)))
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
            // The fallback for a document declaring no success at all. `diagnoseTypedResponses` has
            // already rejected that, so it asserts nothing because it describes nothing.
            ?? SpecResponse(code: 200, contentTypes: ["application/json"], assertions: .none)
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
                // A *typed* nil. The conformer is generic over each controller's parameters, so a bare
                // `nil` leaves a request-scoped controller's parameter uninferable at the template site —
                // the proxy holds no subject for it, only a scope-entry thunk. That thunk's return type
                // names the concrete subject, so passing it to `noSubject` recovers the type without this
                // emitter ever having to spell the proxy's generic parameter names.
                value =
                    controller.genericParameters.isEmpty
                    ? "nil"
                    : "\(namespace).noSubject(self.\(proxyScopeEntry(controller)))"
            }
            return "\(indent)    \(conformerField(controller)): \(value)"
        }
        // The template conformer (`binding == nil`) is built once at registration and dispatches nothing
        // request-scoped, so every worker is `nil` there — as every scoped subject already is. A
        // per-request rebuild fills them from its own scope entry, which is the only thing that has one —
        // and fills only the ones *that* entry yields, since a sibling scoped controller's workers are not
        // on it and naming them would be reaching for a member that does not exist.
        let bindable = binding.map(scopeResolvedWorkers(of:)) ?? []
        let workers = scopeResolvedWorkers.map { worker -> String in
            let value =
                bindable.contains(worker)
                ? "wireOpenAPIEntry.\(scopeYieldFieldName(forType: worker))" : "nil"
            return "\(indent)    \(workerField(worker)): \(value)"
        }
        let context =
            scopeResolvedWorkers.isEmpty
            ? []
            : [
                "\(indent)    \(scopeResolvedRequestField): \(binding == nil ? "nil" : "request")",
                "\(indent)    \(scopeResolvedPathParametersField): \(binding == nil ? "nil" : "parameters")",
            ]
        let all = arguments + workers + context
        return "\(conformer)(\n\(all.joined(separator: ",\n"))\n\(indent))"
    }
}

// MARK: - a mapped error's own body

extension DirectDispatchEmitter {
    /// What a matched `@ErrorResponse` clause runs.
    ///
    /// Ordinarily one `return`. With response validation on and the mapped response carrying a schema
    /// that asserts something, the body is bound first and checked before it is sent — an author's
    /// closure can violate the document exactly as a success value can, and it is built *here*, inside a
    /// `catch`, where the success path's check never runs. Missing this is the easy mistake, because the
    /// success path is the one anybody tests.
    func mappedOutcome(
        _ mapping: ErrorMapping,
        for operation: DiscoveredOperation,
        indent: String
    ) -> String {
        let documented = operationRoutes[operation.operationID]?.responses.first {
            GeneratorStatusNames.safeName(for: $0.code) == mapping.status
        }
        guard let body = mapping.bodyClosure, let documented,
            settings.validatesResponses, carriesChecks(documented.assertions)
        else { return "\(indent)return \(errorOutcome(mapping, for: operation))" }
        let caseName = GeneratorStatusNames.safeName(for: documented.code)
        let check = responseCheck(
            documented.assertions,
            access: "wireOpenAPIMapped",
            operationID: operation.operationID,
            indent: indent
        )
        return """
            \(indent)let wireOpenAPIMapped = try wireOpenAPIErrorBody(wireOpenAPIError, \(body))
            \(check)\(indent)return .\(caseName)(.init(body: .json(wireOpenAPIMapped)))
            """
    }
}
