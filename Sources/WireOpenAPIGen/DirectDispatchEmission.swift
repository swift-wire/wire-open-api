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
// it and point its `handler` at a conformer holding *this* request's subject. One struct copy, no
// registration, no ambient state, and cost independent of how many operations the document declares.
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
    let controller: DiscoveredController
    /// The request-scoped controller of this group, if it has one. Its presence is what decides whether a
    /// request needs its own conformer at all.
    let scoped: DiscoveredController?
    let controllerEntries: [String]
    let operationRoutes: [String: OperationRoute]
    let serverPrefix: ServerPrefix
    let foldEntries: ([String], String) -> [String]

    /// The per-request conformer's type name. Only emitted for a request-scoped group; app-scoped, the
    /// aggregate proxy conforms directly.
    var conformer: String { "_WireOpenAPIRequest_\(sanitizedKeyFragment(spec))" }

    var serverURLArgument: String {
        serverPrefix == .none ? "" : "serverURL: try Servers.Server1.url(), "
    }

    /// `operationId` → the method implementing it.
    var byOperationID: [String: DiscoveredOperation] {
        Dictionary(controller.operations.map { ($0.operationID, $0) }, uniquingKeysWith: { _, last in last })
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

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(
            Data("\(controller.file):\(controller.line): error: \(message)\n".utf8)
        )
        exit(1)
    }

    // MARK: - the conformer

    /// The conformer an operation is called through. Request-scoped: one per request, holding that
    /// request's subject. App-scoped: the aggregate itself, which already holds it as a field.
    ///
    /// Its subject is optional *only* so the server can be built before any request exists. Every dispatch
    /// path sets it, so a `nil` there is not a condition to handle — it means generated code was bypassed,
    /// which is a programming error in this file rather than anything a caller can cause.
    func conformerDeclaration() -> String {
        guard let scoped else {
            return """
                extension \(proxy): APIProtocol {
                \(forwarders(reachingSubject: "_wireSubject").joined(separator: "\n\n"))
                }
                """
        }
        return """
            struct \(conformer): APIProtocol {
                let _wireSubject: \(scoped.typeName)?

            \(forwarders(reachingSubject: nil).joined(separator: "\n\n"))
            }
            """
    }

    /// One forwarder per operation. `reachingSubject` names the expression holding the subject, or `nil`
    /// when it has to be unwrapped from the optional field first.
    private func forwarders(reachingSubject subject: String?) -> [String] {
        controller.operations.map { operation in
            let signature =
                "    func \(operation.methodName)(_ input: \(operation.inputType)) async throws "
                + "-> \(operation.outputType) {"
            guard let subject else {
                return """
                    \(signature)
                            guard let wireOpenAPISubject = _wireSubject else {
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
            return """
                \(signature)
                        try await \(subject).\(operation.methodName)(input)
                    }
                """
        }
    }

    // MARK: - the request path

    /// The terminal: obtain this request's server, then call the operation's own method on it.
    func terminal(_ operation: DiscoveredOperation, indent: String) -> String {
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
        // App-scoped: nothing varies per request, so the server built at registration is used as-is.
        guard scoped != nil else {
            return "\(indent)let wireOpenAPIServer = wireOpenAPIServerTemplate\n" + call
        }
        // Scope entry stays in the terminal, matching M5.4.3: the scope outlives the middleware chain
        // wrapping it, teardown runs after the response, and a failure entering it is raised where
        // `@ErrorResponse` can still map it.
        //
        // The server is *copied* and re-handlered, never constructed here: `UniversalServer.init` builds a
        // `Converter`, which allocates two `JSONEncoder`s and a `JSONDecoder`. Paying that per request
        // costs more than the task-local this exists to avoid — measured, not assumed.
        return """
            \(indent)let (wireOpenAPISubject, wireOpenAPITeardown) = try await self._wireEnterScope(request)
            \(indent)var wireOpenAPIRebound = wireOpenAPIServerTemplate
            \(indent)wireOpenAPIRebound.handler = \(conformer)(_wireSubject: wireOpenAPISubject)
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

    /// One `builder.register`, wrapped in this operation's middleware fold. Controller-scope entries fold
    /// outside route-scope ones, matching WireMVC's ordering (controller-outer → route-inner → handler).
    ///
    /// The path is composed by the runtime's own `apiPathComponentsWithServerPrefix` rather than joined
    /// here. Two derivations of one rule can disagree, and a disagreement would put the route at a path
    /// the document does not describe — so the document supplies only its `paths:` key and the prefix is
    /// applied by the same code the generator would have used.
    func registerBlock(_ operation: DiscoveredOperation, _ route: OperationRoute, indent: String) -> String {
        let entries = controllerEntries + foldEntries(operation.middleware, indent + "            ")
        let register = """
            \(indent)builder.register(
            \(indent)    method: .\(route.method.lowercased()),
            \(indent)    path: try wireOpenAPIServerTemplate.apiPathComponentsWithServerPrefix("\(route.path)")
            \(indent))
            """
        guard !entries.isEmpty else {
            return """
                \(register) { request, _, parameters, reader, sender in
                \(terminal(operation, indent: indent + "    "))
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
            \(terminal(operation, indent: indent + "            "))
            \(indent)        }
            \(indent)    }
            \(indent)}
            """
    }

    // MARK: - the contributor

    /// The conformance the proxy is collated as. The server is built once, here: that is what makes
    /// dispatch O(1). Request-scoped it is the template each request copies and re-handlers; app-scoped it
    /// *is* the server. Either way the `Converter`, and the coders it allocates, are constructed once for
    /// the process.
    func routeContributorDeclaration() -> String {
        // Sorted by operationId so the emitted file is stable across runs — the dictionary is not ordered,
        // and an output that reshuffles between builds re-triggers every downstream compile.
        let marked = byOperationID
        let registrations = operationRoutes.sorted { $0.key < $1.key }
            .compactMap { operationID, route -> String? in
                marked[operationID].map { registerBlock($0, route, indent: "        ") }
            }
        let templateHandler = scoped == nil ? "self" : "\(conformer)(_wireSubject: nil)"
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
