import Foundation
import WireOpenAPINaming

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
    /// The module owning this spec's generated types, when they are not this target's own.
    ///
    /// Two documents generate two `APIProtocol`s, two `Operations`, two `Servers` — spelled identically,
    /// because the generator names them from nothing about the document. In a module importing both, a
    /// bare `Operations.GetTask.Input` is "ambiguous for type lookup", and that includes the spellings
    /// copied verbatim out of a controller that was unambiguous where it was written. Naming the module
    /// is what resolves it (spike-28).
    let specModule: String?
    let operationRoutes: [String: OperationRoute]
    /// Every component schema by its document name, so a `$ref` can be emitted as a call to the
    /// validator for that name rather than expanded in place — which is what terminates on a recursive
    /// schema and keeps the output linear in the document.
    let componentSchemas: [String: SpecAssertions]
    let serverPrefix: ServerPrefix
    /// How this document's symbols are spelled. Read from its generator config rather than assumed —
    /// `GeneratorSafeNames` turns an operationId into `Operations.<X>` and a parameter name into an
    /// `Input` member, and the two strategies disagree about both.
    let namingStrategy: GeneratorNamingStrategy
    /// What `wire-openapi.yaml` beside this document asks for.
    let settings: WireSettings
    let foldEntries: ([String], String) -> [String]

    /// The enum this spec's conformer is emitted inside. It exists to carry typealiases: within it, a
    /// bare `Operations` resolves to *this* spec's module, because a member typealias of an enclosing
    /// type is found before anything imported. That is what lets the forwarders keep the user's own
    /// spellings, qualified or not, with two documents in one module.
    var namespace: String {
        spec.isEmpty ? "_WireOpenAPISpec" : "_WireOpenAPISpec_\(sanitizedKeyFragment(spec))"
    }

    /// The conformer, as named from outside its namespace.
    var conformer: String { "\(namespace).Conformer" }

    /// A generated type of this spec, qualified when it belongs to another module.
    func qualified(_ name: String) -> String {
        specModule.map { "\($0).\(name)" } ?? name
    }

    var serverURLArgument: String {
        serverPrefix == .none ? "" : "serverURL: try \(qualified("Servers")).Server1.url(), "
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

    /// The conformer's field for a graph-aware binding's worker — one per distinct worker in the group,
    /// named after the type so two operations naming the same one share it.
    func workerField(_ worker: String) -> String { "_wireWorker_\(worker)" }
}

/// The conformer's fields for what a worker's `bind` takes beyond the decoded `Input`.
let scopeResolvedRequestField = "_wireRequest"
let scopeResolvedPathParametersField = "_wirePathParameters"

extension DirectDispatchEmitter {

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

    // MARK: - the request path

    /// The terminal: obtain this request's server, then call the operation's own method on it.
    func terminal(
        _ controller: DiscoveredController,
        _ operation: DiscoveredOperation,
        indent: String
    ) -> String {
        // The mappings that can only be matched at the terminal, if any.
        let rejection =
            terminalRejectionClosure(controller, operation, indent: indent + "    ")
            .map { $0 + "\n" } ?? ""
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
            \(indent)    reader: reader,
            \(indent)    sender: ResponseHeaderApplyingSender(wrapping: sender, registry: wireOpenAPIRegistry),
            \(rejection)\(indent)    operationID: "\(operation.operationID)"
            \(indent))
            """
        // This operation's controller is app-scoped: nothing about its dispatch varies per request, so the
        // server built at registration is used as-is — even when a sibling controller is request-scoped.
        guard controller.seed != nil else {
            return "\(indent)let wireOpenAPIServer = wireOpenAPIServerTemplate\n" + call
        }
        // Scope entry stays in the terminal, matching M5.4.3: the scope outlives the middleware chain
        // wrapping it, and teardown runs after the response. Only this operation's own scope is entered.
        //
        // The server is *copied* and re-handlered, never constructed here: `UniversalServer.init` builds a
        // `Converter`, which allocates two `JSONEncoder`s and a `JSONDecoder`. Paying that per request
        // costs more than the task-local this exists to avoid — measured, not assumed.
        let scoped = """
            \(indent)let wireOpenAPISubject = wireOpenAPIEntry._wireSubject
            \(indent)let wireOpenAPITeardown = wireOpenAPIEntry._wireScopeTeardown
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
        return enteringScope(controller, serving: scoped, indent: indent)
    }

    /// The scope entry itself, and what happens when it fails.
    ///
    /// Entering the scope is the one thing in the terminal that happens *outside* every `catch` the
    /// conformer emits, and it has to be: the entry produces the subject the conformer is built around,
    /// and the scope has to outlive the response so teardown runs after it. So a `@Scoped(seed:)` binding
    /// that throws — an unauthenticated request failing to build its `Caller` — reached the router with no
    /// response to write, which is a dropped connection rather than a status. When the controller wrote
    /// mappings, the failure is branched on here and answered with them.
    private func enteringScope(
        _ controller: DiscoveredController,
        serving scoped: String,
        indent: String
    ) -> String {
        guard let rejection = scopeEntryRejectionClosure(controller, indent: indent + "        ") else {
            // Nothing to answer with, so nothing is gained by the branch: the original straight-line
            // shape, and the throw still escapes exactly as it did.
            return "\(indent)let wireOpenAPIEntry = try await self.\(proxyScopeEntry(controller))(request)\n"
                + scoped
        }
        let served = scoped.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")
        return """
            \(indent)let wireOpenAPIEntered = await WireOpenAPIRoutes.enteringScope {
            \(indent)    try await self.\(proxyScopeEntry(controller))(request)
            \(indent)}
            \(indent)switch wireOpenAPIEntered {
            \(indent)case .failure(let wireOpenAPIScopeFailure):
            \(indent)    try await WireOpenAPIRoutes.refuse(
            \(indent)        wireOpenAPIScopeFailure,
            \(rejection)
            \(indent)        sender: ResponseHeaderApplyingSender(
            \(indent)            wrapping: sender, registry: wireOpenAPIRegistry
            \(indent)        )
            \(indent)    )
            \(indent)case .success(let wireOpenAPIEntry):
            \(served)
            \(indent)}
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
        // Every registration is wrapped in its own `do`, and the body indented one level inside it, so
        // the path local below is scoped to one route. The alternative — a name derived from the
        // operationId — would need sanitising, since an operationId is not required to be a Swift
        // identifier (`get-task`, `list_tasks`); a block needs no name at all and cannot collide however
        // many operations a document declares.
        let body = indent + "    "
        let entries =
            foldEntries(controller.middleware, body + "            ")
            + foldEntries(operation.middleware, body + "            ")
        // Bound to a local rather than written inline, so the path the route registers under and the
        // template its `RouteContext` carries are the same string by construction — and composed once,
        // rather than once per request, since the runtime's prefixing throws.
        let register = """
            \(body)let wireOpenAPIPath = try wireOpenAPIServerTemplate
            \(body)    .apiPathComponentsWithServerPrefix("\(route.path)")
            \(body)builder.register(method: .\(route.method.lowercased()), path: wireOpenAPIPath)
            """
        guard !entries.isEmpty else {
            return """
                \(indent)do {
                \(register) { request, requestContext, parameters, reader, sender in
                \(body)    let wireOpenAPIContents = requestContext.takeContents()
                \(body)    let wireOpenAPIRegistry = wireOpenAPIContents.responseHeaders.take()
                \(terminal(controller, operation, indent: body + "    "))
                \(body)}
                \(indent)}
                """
        }
        return """
            \(indent)do {
            \(register) {
            \(body)    request, requestContext, parameters, reader, responseSender in
            \(body)    let wireOpenAPIContents = requestContext.takeContents()
            \(body)    let wireOpenAPIBase = wireOpenAPIContents.base
            \(body)    let wireOpenAPIBox = RequestResponseMiddlewareBox.pending(
            \(body)        request: request, requestContext: wireOpenAPIBase,
            \(body)        route: RouteContext(template: wireOpenAPIPath, pathParameters: parameters),
            \(body)        reader: reader,
            \(body)        responseSender: responseSender,
            \(body)        responseHeaders: wireOpenAPIContents.responseHeaders.take()
            \(body)    )
            \(body)    let wireOpenAPIChain = wireCompose {
            \(entries.joined(separator: "\n"))
            \(body)    }
            \(body)    try await wireOpenAPIChain.intercept(input: wireOpenAPIBox) { wireOpenAPIFinalBox in
            \(body)        try await wireOpenAPIFinalBox.withPendingContents {
            \(body)            request, _, _, reader, sender, wireOpenAPIRegistry in
            \(terminal(controller, operation, indent: body + "            "))
            \(body)        }
            \(body)    }
            \(body)}
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
        let templateHandler = conformerLiteral(binding: nil, indent: "            ")
        return """
            extension \(proxy): RouteContributor {
                func registerWireRoutes<Builder: HTTPServerRouteBuilder>(
                    on builder: inout Builder,
                    coding wireMVCAppCoding: WireMVCCoding
                ) throws
                where
                    Builder.RequestContext: ~Copyable & SendableMetatype & ResponseHeaderCarrying,
                    Builder.Reader: ~Copyable,
                    Builder.ResponseSender: ~Copyable,
                    Builder.ResponseSender.Writer: ~Copyable
                {
                    let wireOpenAPIServerTemplate = UniversalServer(
                        \(serverURLArgument)handler: \(templateHandler),
                        configuration: Configuration(wireMVCCoding: wireMVCAppCoding)
                    )
            \(registrations.joined(separator: "\n"))
                }
            }
            """
    }
}
