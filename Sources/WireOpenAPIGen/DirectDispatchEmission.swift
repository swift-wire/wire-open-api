import Foundation

// Mounting a spec's operations as WireMVC routes, dispatched directly.
//
// `registerHandlers` bakes `let server = UniversalServer(handler: self, …)` into every closure it hands
// the transport, *by value*. That is what makes a request-scoped subject awkward: the handler is fixed at
// registration, so reaching it later needs either a task-local the forwarder reads or a fresh
// registration per request — both working around the same thing, and both measurably worse (see the
// `m6d-request-scope-strategies` branch, which keeps all three side by side with the numbers).
//
// The generated per-operation methods on `UniversalServer` — which hold the only copy of an operation's
// deserializer/serializer pair — remove the problem: build a `UniversalServer` once, and per request copy
// it and point its `handler` at a conformer holding *this* request's subjects. One struct copy, no
// registration, no ambient state, and cost independent of how many operations the document declares.
//
// Dispatching per operation is also what lets several controllers share one document. Nothing here
// registers a whole spec from a single object any more: each operation is mounted individually and
// forwarded to the controller that declared it, and `APIProtocol` conformance is what makes the compiler
// check the set is complete.
//
// The catch is access: stock swift-openapi-generator emits that extension `fileprivate`, so nothing
// outside its own `Server.swift` can call it. This needs it `internal` — a one-line change in
// `ServerTranslator.swift`, sufficient because this file compiles into the same module — carried on a
// fork until it lands upstream.

/// One spec's worth of emission. A type rather than a function so each part of the output — the
/// conformer, a terminal, a registration, the contributor — is readable on its own, and so the inputs
/// they share are named once rather than threaded through every call.
struct DirectDispatchEmitter {
    let spec: String
    let proxy: String
    /// Every `@OpenAPIController` sharing this spec, in discovery order. Each contributes the operations
    /// it declares and its own controller-scope `@Middleware`; scoping is decided per controller, so a
    /// group may mix request-scoped and app-scoped ones.
    let controllers: [DiscoveredController]
    let operationRoutes: [String: OperationRoute]
    let serverPrefix: ServerPrefix
    let foldEntries: ([String], String) -> [String]

    /// The per-request conformer's type name. Only emitted when some controller is request-scoped;
    /// otherwise the aggregate proxy conforms directly, holding every subject as a field.
    var conformer: String { "_WireOpenAPIRequest_\(sanitizedKeyFragment(spec))" }

    var serverURLArgument: String {
        serverPrefix == .none ? "" : "serverURL: try Servers.Server1.url(), "
    }

    /// swift-wire names a lone subject positionally (`_wireSubject`, `_wireEnterScope`) and labels each of
    /// several (`_wireSubject_<Subject>`, `_wireEnterScope_<Subject>`). Matching that here is the whole
    /// handshake with the structural half of the proxy — a mismatch is a "no member" error at the fold.
    var subjectsAreLabelled: Bool { controllers.count > 1 }

    private func suffix(_ controller: DiscoveredController) -> String {
        subjectsAreLabelled ? "_\(controller.typeName)" : ""
    }

    func proxySubjectField(_ controller: DiscoveredController) -> String {
        "_wireSubject\(suffix(controller))"
    }

    func proxyScopeEntry(_ controller: DiscoveredController) -> String {
        "_wireEnterScope\(suffix(controller))"
    }

    /// The conformer's own field for a subject. Named the same way as the proxy's, so the two read alike.
    func conformerField(_ controller: DiscoveredController) -> String {
        "_wireSubject\(suffix(controller))"
    }

    var scopedControllers: [DiscoveredController] { controllers.filter { $0.seed != nil } }

    /// A separate conformer is needed only when something is built per request. With every controller
    /// app-scoped the aggregate already holds each subject, so it conforms directly.
    var needsConformer: Bool { !scopedControllers.isEmpty }

    /// `operationId` → the controller that declared it and the method implementing it.
    var byOperationID: [String: (controller: DiscoveredController, operation: DiscoveredOperation)] {
        var found: [String: (controller: DiscoveredController, operation: DiscoveredOperation)] = [:]
        for controller in controllers {
            for operation in controller.operations { found[operation.operationID] = (controller, operation) }
        }
        return found
    }

    /// Emit this spec's conformer and the contributor that mounts its operations.
    func emit(into lines: inout [String]) {
        diagnoseCoverage()
        lines.append(conformerDeclaration())
        lines.append("")
        lines.append(routeContributorDeclaration())
        lines.append("")
    }

    // MARK: - diagnostics

    /// Routes come from the *document* rather than from replaying a registration, so every operation it
    /// declares has to name a method here. Without the marker there is no method name to call, and no way
    /// to derive one that does not re-do the generator's safe-name transform — so an unmarked operation is
    /// an error naming it, not a route that silently never appears.
    func diagnoseCoverage() {
        if operationRoutes.isEmpty {
            fail(
                """
                @OpenAPIController needs the OpenAPI document to derive its routes, and none was passed \
                (--spec).
                """
            )
        }
        diagnoseDuplicates()
        let marked = byOperationID
        let missing = operationRoutes.keys.filter { marked[$0] == nil }.sorted()
        guard !missing.isEmpty else { return }
        fail(
            """
            every operation the document declares must carry @RawOperation, and \
            \(missing.joined(separator: ", ")) \(missing.count == 1 ? "does" : "do") not. Mark the \
            \(missing.count == 1 ? "method that implements it" : "methods that implement them").
            """
        )
    }

    /// Two controllers implementing one operationId would each be a plausible target and only one could
    /// be mounted, so the document decides nothing and the choice would be discovery order. Reject it
    /// rather than mount whichever came last.
    private func diagnoseDuplicates() {
        var owners: [String: [String]] = [:]
        for controller in controllers {
            for operation in controller.operations {
                owners[operation.operationID, default: []].append(controller.typeName)
            }
        }
        let clashes = owners.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
        guard let (operationID, named) = clashes.first else { return }
        fail(
            """
            \(named.sorted().joined(separator: " and ")) both declare @RawOperation \
            '\(operationID)'. One operation is mounted once, so exactly one controller may implement it.
            """
        )
    }

    private func fail(_ message: String) -> Never {
        let location = controllers[0]
        FileHandle.standardError.write(
            Data("\(location.file):\(location.line): error: \(message)\n".utf8)
        )
        exit(1)
    }

    // MARK: - the conformer

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
        guard needsConformer else {
            return """
                extension \(proxy): APIProtocol {
                \(forwarders.joined(separator: "\n\n"))
                }
                """
        }
        let fields = controllers.map { controller in
            "    let \(conformerField(controller)): \(controller.typeName)"
                + (controller.seed != nil ? "?" : "")
        }
        return """
            struct \(conformer): APIProtocol {
            \(fields.joined(separator: "\n"))

            \(forwarders.joined(separator: "\n\n"))
            }
            """
    }

    /// One operation, forwarded to the controller that declared it.
    private func forwarder(_ controller: DiscoveredController, _ operation: DiscoveredOperation) -> String {
        let signature =
            "    func \(operation.methodName)(_ input: \(operation.inputType)) async throws "
            + "-> \(operation.outputType) {"
        // App-scoped inside a conformer, or any subject on a directly-conforming proxy: a stored field.
        guard needsConformer, controller.seed != nil else {
            let field = needsConformer ? conformerField(controller) : proxySubjectField(controller)
            return """
                \(signature)
                        try await \(field).\(operation.methodName)(input)
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
    private func conformerLiteral(binding: DiscoveredController?, indent: String) -> String {
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

    // MARK: - the request path

    /// The terminal: obtain this request's server, then call the operation's own method on it.
    func terminal(
        _ controller: DiscoveredController,
        _ operation: DiscoveredOperation,
        indent: String
    ) -> String {
        let call = """
            \(indent)let wireOpenAPIHandler:
            \(indent)    @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
            \(indent)        HTTPResponse, HTTPBody?
            \(indent)    ) = { wireOpenAPIRequest, wireOpenAPIBody, wireOpenAPIMetadata in
            \(indent)        try await wireOpenAPIServer.\(operation.methodName)(
            \(indent)            request: wireOpenAPIRequest, body: wireOpenAPIBody,
            \(indent)            metadata: wireOpenAPIMetadata
            \(indent)        )
            \(indent)    }
            \(indent)try await WireOpenAPIRoutes.invoke(
            \(indent)    handler: wireOpenAPIHandler, request: request, pathParameters: parameters,
            \(indent)    reader: reader, sender: sender
            \(indent))
            """
        // This operation's controller is app-scoped: nothing about its dispatch varies per request, so the
        // server built at registration is used as-is — even when a sibling controller is request-scoped.
        guard controller.seed != nil else {
            return "\(indent)let wireOpenAPIServer = wireOpenAPIServerTemplate\n" + call
        }
        // Scope entry stays in the terminal, matching M5.4.3: the scope outlives the middleware chain
        // wrapping it, teardown runs after the response, and a failure entering it is raised where
        // `@ErrorResponse` can still map it. Only this operation's own scope is entered.
        //
        // The server is *copied* and re-handlered, never constructed here: `UniversalServer.init` builds a
        // `Converter`, which allocates two `JSONEncoder`s and a `JSONDecoder`. Paying that per request
        // costs more than the task-local this exists to avoid — measured, not assumed.
        return """
            \(indent)let (wireOpenAPISubject, wireOpenAPITeardown) = try await self.\
            \(proxyScopeEntry(controller))(request)
            \(indent)var wireOpenAPIRebound = wireOpenAPIServerTemplate
            \(indent)wireOpenAPIRebound.handler = \(conformerLiteral(binding: controller, indent: indent))
            \(indent)// `let`, because the handler closure below is `@Sendable` and cannot capture a `var`.
            \(indent)let wireOpenAPIServer = wireOpenAPIRebound
            \(indent)do {
            \(call)
            \(indent)} catch {
            \(indent)    _ = await wireOpenAPITeardown()
            \(indent)    throw error
            \(indent)}
            \(indent)_ = await wireOpenAPITeardown()
            """
    }

    /// One `builder.register`, wrapped in this operation's middleware fold. Controller-scope entries come
    /// from the controller that *declared* the operation — a group's controllers do not share a fold —
    /// and fold outside route-scope ones, matching WireMVC's ordering (controller-outer → route-inner →
    /// handler).
    ///
    /// The path is composed by the runtime's own `apiPathComponentsWithServerPrefix` rather than joined
    /// here. Two derivations of one rule can disagree, and a disagreement would put the route at a path
    /// the document does not describe — so the document supplies only its `paths:` key and the prefix is
    /// applied by the same code the generator would have used.
    func registerBlock(
        _ controller: DiscoveredController,
        _ operation: DiscoveredOperation,
        _ route: OperationRoute,
        indent: String
    ) -> String {
        let entries =
            foldEntries(controller.middleware, indent + "            ")
            + foldEntries(operation.middleware, indent + "            ")
        let register = """
            \(indent)builder.register(
            \(indent)    method: .\(route.method.lowercased()),
            \(indent)    path: try wireOpenAPIServerTemplate.apiPathComponentsWithServerPrefix("\(route.path)")
            \(indent))
            """
        guard !entries.isEmpty else {
            return """
                \(register) { request, _, parameters, reader, sender in
                \(terminal(controller, operation, indent: indent + "    "))
                \(indent)}
                """
        }
        return """
            \(register) {
            \(indent)    request, requestContext, parameters, reader, responseSender in
            \(indent)    let wireOpenAPIBox = RequestResponseMiddlewareBox.pending(
            \(indent)        request: request, requestContext: requestContext, reader: reader,
            \(indent)        responseSender: responseSender
            \(indent)    )
            \(indent)    let wireOpenAPIChain = wireCompose {
            \(entries.joined(separator: "\n"))
            \(indent)    }
            \(indent)    try await wireOpenAPIChain.intercept(input: wireOpenAPIBox) { wireOpenAPIFinalBox in
            \(indent)        try await wireOpenAPIFinalBox.withPendingContents { request, _, reader, sender in
            \(terminal(controller, operation, indent: indent + "            "))
            \(indent)        }
            \(indent)    }
            \(indent)}
            """
    }

    // MARK: - the contributor

    /// The conformance the proxy is collated as. The server is built once, here: that is what makes
    /// dispatch O(1). With a request-scoped controller it is the template each such request copies and
    /// re-handlers; with none it *is* the server. Either way the `Converter`, and the coders it allocates,
    /// are constructed once for the process.
    func routeContributorDeclaration() -> String {
        // Sorted by operationId so the emitted file is stable across runs — the dictionary is not ordered,
        // and an output that reshuffles between builds re-triggers every downstream compile.
        let owners = byOperationID
        let registrations = operationRoutes.sorted { $0.key < $1.key }
            .compactMap { operationID, route -> String? in
                owners[operationID].map { registerBlock($0.controller, $0.operation, route, indent: "        ") }
            }
        let templateHandler =
            needsConformer ? conformerLiteral(binding: nil, indent: "            ") : "self"
        return """
            extension \(proxy): RouteContributor {
                func registerWireRoutes<Builder: HTTPServerRouteBuilder>(on builder: inout Builder) throws
                where
                    Builder.RequestContext: ~Copyable & SendableMetatype,
                    Builder.Reader: ~Copyable,
                    Builder.ResponseSender: ~Copyable,
                    Builder.ResponseSender.Writer: ~Copyable
                {
                    let wireOpenAPIServerTemplate = UniversalServer(
                        \(serverURLArgument)handler: \(templateHandler)
                    )
            \(registrations.joined(separator: "\n"))
                }
            }
            """
    }
}
