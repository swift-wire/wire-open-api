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

/// `HTTPRequest.Method` for a document's method name.
private func methodLiteral(_ method: String) -> String { ".\(method.lowercased())" }

/// Emit a spec's route registrations, plus the conformer they dispatch through.
func emitDirectDispatch(
    spec: String,
    proxy: String,
    controller: DiscoveredController,
    scoped: DiscoveredController?,
    controllerEntries: [String],
    operationRoutes: [String: OperationRoute],
    serverPrefix: ServerPrefix,
    foldEntries: ([String], String) -> [String],
    into lines: inout [String]
) {
    let conformer = "_WireOpenAPIRequest_\(sanitizedKeyFragment(spec))"
    let serverURLArgument = serverPrefix == .none ? "" : "serverURL: try Servers.Server1.url(), "

    // Routes come from the *document* rather than from replaying a registration, so every operation it
    // declares has to name a method here. Without the marker there is no method name to call, and no way
    // to derive one that does not re-do the generator's safe-name transform — so an unmarked operation is
    // an error naming it, not a route that silently never appears.
    var byOperationID: [String: DiscoveredOperation] = [:]
    for operation in controller.operations { byOperationID[operation.operationID] = operation }

    if operationRoutes.isEmpty {
        FileHandle.standardError.write(
            Data(
                """
                \(controller.file):\(controller.line): error: @OpenAPIController needs the OpenAPI \
                document to derive its routes, and none was passed (--spec).

                """.utf8
            )
        )
        exit(1)
    }
    let missing = operationRoutes.keys.filter { byOperationID[$0] == nil }.sorted()
    if !missing.isEmpty {
        FileHandle.standardError.write(
            Data(
                """
                \(controller.file):\(controller.line): error: every operation the document declares must \
                carry @RawOperation, and \(missing.joined(separator: ", ")) \
                \(missing.count == 1 ? "does" : "do") not. Mark the \
                \(missing.count == 1 ? "method that implements it" : "methods that implement them").

                """.utf8
            )
        )
        exit(1)
    }

    // The conformer an operation is called through. Request-scoped: one per request, holding that
    // request's subject. App-scoped: the aggregate itself, which already holds it as a field.
    //
    // Its subject is optional *only* so the server can be built before any request exists (see below).
    // Every dispatch path sets it, so a `nil` here is not a condition to handle — it means generated code
    // was bypassed, which is a programming error in this file rather than anything a caller can cause.
    if let scoped {
        let forwarders = controller.operations.map { operation in
            """
                func \(operation.methodName)(_ input: \(operation.inputType)) async throws -> \(operation.outputType) {
                    guard let wireOpenAPISubject = _wireSubject else {
                        preconditionFailure(
                            "WireOpenAPI: '\(operation.operationID)' was dispatched with no request-scoped "
                                + "subject bound. The route terminal binds one before every call."
                        )
                    }
                    return try await wireOpenAPISubject.\(operation.methodName)(input)
                }
            """
        }
        lines.append(
            """
            struct \(conformer): APIProtocol {
                let _wireSubject: \(scoped.typeName)?

            \(forwarders.joined(separator: "\n\n"))
            }
            """
        )
    } else {
        let forwarders = controller.operations.map { operation in
            """
                func \(operation.methodName)(_ input: \(operation.inputType)) async throws -> \(operation.outputType) {
                    try await _wireSubject.\(operation.methodName)(input)
                }
            """
        }
        lines.append(
            """
            extension \(proxy): APIProtocol {
            \(forwarders.joined(separator: "\n\n"))
            }
            """
        )
    }
    lines.append("")

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
            \(indent)    method: \(methodLiteral(route.method)),
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

    // Sorted by operationId so the emitted file is stable across runs — the dictionary is not ordered, and
    // an output that reshuffles between builds re-triggers every downstream compile.
    let registrations = operationRoutes.sorted { $0.key < $1.key }
        .compactMap { operationID, route -> String? in
            byOperationID[operationID].map { registerBlock($0, route, indent: "        ") }
        }

    // Built once, at registration: this is what makes dispatch O(1). Request-scoped it is the template
    // each request copies and re-handlers; app-scoped it *is* the server. Either way the `Converter`, and
    // the coders it allocates, are constructed once for the process.
    let templateHandler = scoped == nil ? "self" : "\(conformer)(_wireSubject: nil)"

    lines.append(
        """
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
    )
    lines.append("")
}
