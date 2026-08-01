import Foundation

// Direct dispatch: the request path with neither ambient state nor per-request registration.
//
// `registerHandlers` bakes `let server = UniversalServer(handler: self, …)` into every closure it hands
// the transport, *by value*. That is the whole reason a request-scoped subject is awkward: the handler is
// fixed at registration, so reaching it later needs either a task-local the forwarder reads, or a fresh
// registration per request. Both are working around the same thing.
//
// The generated per-operation methods on `UniversalServer` — which hold the only copy of an operation's
// deserializer/serializer pair — remove the problem entirely: build a `UniversalServer` around a conformer
// holding *this* request's subject and call the operation. One struct construction, no registration, no
// ambient state, and cost independent of how many operations the document declares.
//
// The catch is access: swift-openapi-generator emits that extension `fileprivate`, so nothing outside its
// own `Server.swift` can call it. This strategy needs it emitted `internal` — a one-line change
// (`ServerTranslator.swift`, `accessModifier: .fileprivate` → `nil`), sufficient because this file compiles
// into the same module. Until that lands upstream it is opt-in via `--request-scope=direct`.

/// `HTTPRequest.Method` for a document's method name.
private func methodLiteral(_ method: String) -> String { ".\(method.lowercased())" }

/// Emit a spec's route registrations as direct `UniversalServer` calls, plus the conformer they dispatch
/// through.
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

    // Direct dispatch registers routes from the *document* rather than from a collector, so every
    // operation the document declares has to name a method here. Without the marker there is no method
    // name to call and no way to derive one that does not re-do the generator's safe-name transform — so
    // an unmarked operation is an error naming the operation, not a route that silently never appears.
    var byOperationID: [String: DiscoveredOperation] = [:]
    for operation in controller.operations { byOperationID[operation.operationID] = operation }

    let missing = operationRoutes.keys.filter { byOperationID[$0] == nil }.sorted()
    if !missing.isEmpty {
        FileHandle.standardError.write(
            Data(
                """
                \(controller.file):\(controller.line): error: direct dispatch needs every operation the \
                document declares to carry @RawOperation, and \(missing.joined(separator: ", ")) \
                \(missing.count == 1 ? "does" : "do") not. Mark the \
                \(missing.count == 1 ? "method" : "methods") that implement \
                \(missing.count == 1 ? "it" : "them").

                """.utf8
            )
        )
        exit(1)
    }
    if operationRoutes.isEmpty {
        FileHandle.standardError.write(
            Data(
                """
                \(controller.file):\(controller.line): error: direct dispatch derives its routes from the \
                OpenAPI document, and none was passed (--spec). Pass the document, or use \
                --request-scope=taskLocal.

                """.utf8
            )
        )
        exit(1)
    }

    // The conformer the operation is called through. Request-scoped: one per request, holding that
    // request's subject. App-scoped: the aggregate itself.
    //
    // Its subject is optional only so the `UniversalServer` **template** can be built before any request
    // exists (see below) — the request path always supplies one, and a `nil` there means the route was
    // reached without scope entry, which is a bug rather than a condition to tolerate.
    let forwarders = controller.operations.map { operation in
        """
            func \(operation.methodName)(_ input: \(operation.inputType)) async throws -> \(operation.outputType) {
                guard let wireOpenAPISubject = _wireSubject else {
                    throw WireOpenAPIRoutes.OutsideRequest(operation: "\(operation.operationID)")
                }
                return try await wireOpenAPISubject.\(operation.methodName)(input)
            }
        """
    }
    let appScopedForwarders = controller.operations.map { operation in
        """
            func \(operation.methodName)(_ input: \(operation.inputType)) async throws -> \(operation.outputType) {
                try await _wireSubject.\(operation.methodName)(input)
            }
        """
    }
    if let scoped {
        lines.append(
            """
            struct \(conformer): APIProtocol {
                let _wireSubject: \(scoped.typeName)?

            \(forwarders.joined(separator: "\n\n"))
            }
            """
        )
    } else {
        let forwarders = appScopedForwarders
        lines.append(
            """
            extension \(proxy): APIProtocol {
            \(forwarders.joined(separator: "\n\n"))
            }
            """
        )
    }
    lines.append("")

    /// The terminal: obtain the request's conformer, then call the operation's own method on a
    /// `UniversalServer` wrapping it.
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
        guard scoped != nil else {
            // App-scoped: `wireOpenAPIServer` is the one built at registration.
            return call
        }
        // Scope entry stays in the terminal, matching M5.4.3: the scope outlives the middleware chain
        // wrapping it, teardown runs after the response, and a failure to enter is raised where
        // `@ErrorResponse` can still map it.
        //
        // The server is *copied* from the template and only its handler replaced, never constructed here:
        // `UniversalServer.init` builds a `Converter`, which allocates two `JSONEncoder`s and a
        // `JSONDecoder`. Paying that per request costs more than the task-local this strategy exists to
        // avoid — measured, not assumed.
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
    func registerBlock(_ operation: DiscoveredOperation, _ route: OperationRoute, indent: String) -> String {
        let entries = controllerEntries + foldEntries(operation.middleware, indent + "            ")
        let register = "\(indent)builder.register(method: \(methodLiteral(route.method)), path: \"\(route.path)\")"
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
            guard let operation = byOperationID[operationID] else { return nil }
            return registerBlock(operation, route, indent: "        ")
        }

    // Built once, at registration. App-scoped there is nothing per-request at all, so this *is* the
    // server; request-scoped it is the template each request copies and re-handlers. Either way the
    // `Converter` — and the coders it allocates — is constructed once for the process, which is what makes
    // this strategy O(1) in a way per-request registration is not.
    let sharedServer =
        scoped == nil
        ? "        let wireOpenAPIServer = UniversalServer(\(serverURLArgument)handler: self)\n"
        : "        let wireOpenAPIServerTemplate = UniversalServer(\n"
            + "            \(serverURLArgument)handler: \(conformer)(_wireSubject: nil)\n        )\n"

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
        \(sharedServer)\(registrations.joined(separator: "\n"))
            }
        }
        """
    )
    lines.append("")
}
