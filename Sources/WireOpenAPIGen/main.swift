import Foundation
import SwiftParser
import SwiftSyntax
import Yams

// WireOpenAPIGen — the domain half of WireOpenAPI's codegen, the counterpart to WireMVC's
// `WireMVCRouteGen`.
//
// swift-wire's WireGen emits the *structural* half of the contributor proxy: the struct, its fields
// (`_wireSubject`, or `_wireSubject_<Subject>` when a group holds several), its initialiser, and
// `Sendable` — with a body hole. This tool fills that hole with the `TransportContributor` conformance
// whose witness calls the OpenAPI generator's `registerHandlers`.
//
// It cannot live in the `@OpenAPIController` macro. `TransportContributor` refines `Sendable`, and Swift
// requires a `Sendable` conformance in the type's own file, so the conformance can only be attached to a
// type declared in the same generated module — the proxy — which the macro cannot see.
//
// Usage: WireOpenAPIGen <output.swift> [--spec <openapi.yaml>] [--import <Module>]... [--module <Name> <source.swift>...]...
//
// Each proxy gets BOTH conformances, unconditionally. `RouteContributor` is what the proxy is collated
// as — operations are routes, serving under the same router, `@NotFound`, error tiers and composition
// root as annotation-driven ones. `TransportContributor` is the shape `registerHandlers` needs, used by
// the route registration itself, which replays it against a collecting transport.

// MARK: - argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
guard let outputPath = arguments.first else {
    FileHandle.standardError.write(Data("WireOpenAPIGen: missing output path\n".utf8))
    exit(1)
}
arguments.removeFirst()

var imports: [String] = []
var specPaths: [String] = []
/// How a request-scoped subject reaches the operation handler. Two strategies, kept side by side so
/// they can be measured against each other rather than argued about:
///   • `taskLocal`  — one conformer, captured at bootstrap; the terminal binds the subject to a
///                    task-local the forwarder reads. O(1) per request, ambient state.
///   • `perRequest` — a fresh conformer holding the subject is registered per request and its handler
///                    taken by index. No ambient state, but `registerHandlers` runs per request, which
///                    is O(operations in the document) — a closure and a `URLComponents` parse each.
///   • `direct`     — no registration at all: the terminal builds a `UniversalServer` around a conformer
///                    holding this request's subject and calls the operation's own method on it. O(1),
///                    no ambient state. Needs the generator to emit its `UniversalServer` extension as
///                    internal rather than fileprivate, so it is opt-in until that lands upstream.
var requestScopeStrategy = "taskLocal"
var sourcePaths: [String] = []
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--request-scope":
        index += 1
        if index < arguments.count { requestScopeStrategy = arguments[index] }
    case "--spec":
        index += 1
        if index < arguments.count { specPaths.append(arguments[index]) }
    case "--import":
        index += 1
        if index < arguments.count { imports.append(arguments[index]) }
    case "--module":
        index += 1  // the module name itself is not needed: the emitted extension is module-local
    default:
        sourcePaths.append(arguments[index])
    }
    index += 1
}

let discovered = discoverControllers(in: sourcePaths)

// MARK: - grouping

/// The proxy type swift-wire synthesises for a group — `_WireOpenAPIContributor` for the default group,
/// `_WireOpenAPIContributor_<Spec>` otherwise. Must match `aggregateProxyTypeName` in WireGenCore.
func proxyTypeName(for spec: String?) -> String {
    guard let spec, !spec.isEmpty else { return "_WireOpenAPIContributor" }
    let sanitised = String(spec.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    return "_WireOpenAPIContributor_\(sanitised)"
}

var byGroup: [String: [DiscoveredController]] = [:]
for controller in discovered {
    byGroup[controller.spec ?? "", default: []].append(controller)
}

// One conformer per spec is not a preference — `registerHandlers` is generated once per document and
// registers every operation from a single handler, so two controllers on one spec would each register the
// whole spec. Splitting a spec across controllers needs the proxy to *implement* `APIProtocol` and
// dispatch per operation, which is a later milestone; until then this is a hard error rather than silent
// double registration.
for (spec, controllers) in byGroup where controllers.count > 1 {
    let named = controllers.map(\.typeName).sorted().joined(separator: ", ")
    let label = spec.isEmpty ? "the default spec" : "spec '\(spec)'"
    let location = controllers[0]
    FileHandle.standardError.write(
        Data(
            """
            \(location.file):\(location.line): error: \(controllers.count) @OpenAPIController types share \
            \(label) (\(named)). The OpenAPI generator emits one registerHandlers per document, so each \
            would register every operation. Give them distinct `spec:` values, or wait for generated \
            per-operation dispatch.

            """.utf8
        )
    )
    exit(1)
}

// What the document says: the prefix operations register under, and where each operationId lands.
let serverPrefix = resolveServerPrefix(specPaths: specPaths)
let operationRoutes = resolveOperationRoutes(specPaths: specPaths)

// MARK: - emission

// `WireOpenAPI` and `OpenAPIRuntime` are always needed (the conformance and its `ServerTransport`
// parameter); a Wire-aware dependency may name either, so the set is deduplicated rather than appended —
// a repeated import compiles but reads like a codegen bug.
let allImports = Set(["Foundation", "OpenAPIRuntime", "WireMVC", "WireOpenAPI"] + imports).sorted()
/// Direct dispatch names `UniversalServer`, which the runtime marks `@_spi(Generated)` — the same import
/// the generator's own `Server.swift` writes.
let directStrategy = requestScopeStrategy == "direct"
var lines: [String] = ["// Generated by WireOpenAPIGen — do not edit.", ""]
lines += allImports.map { $0 == "OpenAPIRuntime" && directStrategy ? "@_spi(Generated) import \($0)" : "import \($0)" }
lines.append("")

let serverURLArgument = serverPrefix == .none ? "" : ", serverURL: try Servers.Server1.url()"

for (spec, controllers) in byGroup.sorted(by: { $0.key < $1.key }) {
    guard let controller = controllers.first else { continue }
    let proxy = proxyTypeName(for: spec.isEmpty ? nil : spec)

    let scopedSubject = controllers.first(where: { $0.seed != nil })
    let perRequestStrategy = requestScopeStrategy == "perRequest" && scopedSubject != nil

    // Controller-scope `@Middleware`, folded around every operation of this spec. The fold is emitted
    // *here* rather than run from a helper because `wireCompose` returns the chain's concrete composed
    // type — erasing it would stop the terminal reading the final box's contents.
    //
    // Each entry names a field Wire has already lifted onto the proxy: `T.self` injects the binding by
    // type, a `FactoryKey` a synthesised factory whose `create` is specialised at the builder's box
    // roles. Same spelling WireMVC's route codegen uses, so one `@Middleware(RequireAPIKey.self)`
    // component serves an operation and a `@Get` alike.
    func foldEntries(_ arguments: [String], indent: String) -> [String] {
        arguments.map { argument in
            if argument.hasSuffix(".self") {
                return indent + "self.\(dependencyPropertyName(forType: String(argument.dropLast(5))))"
            }
            return indent + "self._wireFactory_\(sanitizedKeyFragment(argument))"
                + ".create(Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)"
        }
    }

    // Controller-scope entries fold *outside* route-scope ones, matching WireMVC's ordering
    // (controller-outer → route-inner → handler).
    let controllerEntries = foldEntries(controller.middleware, indent: "            ")

    if directStrategy {
        emitDirectDispatch(
            spec: spec,
            proxy: proxy,
            controller: controller,
            scoped: scopedSubject,
            controllerEntries: controllerEntries,
            operationRoutes: operationRoutes,
            serverPrefix: serverPrefix,
            foldEntries: foldEntries,
            into: &lines
        )
        continue
    }

    // Route-scope middleware needs each method matched to the route its operation registers as. The
    // collector reports only (method, path), so the document supplies the mapping — and a method whose
    // operationId the document doesn't declare is an error rather than middleware that silently never
    // runs, which is the failure the marker exists to prevent.
    var routeCases: [(route: OperationRoute, entries: [String])] = []
    for operation in controller.operations where !operation.middleware.isEmpty {
        guard let route = operationRoutes[operation.operationID] else {
            FileHandle.standardError.write(
                Data(
                    """
                    \(controller.file):\(controller.line): error: @RawOperation \
                    '\(operation.operationID)' carries @Middleware but the document declares no such \
                    operationId. Name the operation it implements — @RawOperation("the-id") — or remove \
                    the middleware.

                    """.utf8
                )
            )
            exit(1)
        }
        routeCases.append((route: route, entries: foldEntries(operation.middleware, indent: "                    ")))
    }
    /// One `builder.register` call, wrapped in `entries` if there are any. The fold is emitted inline
    /// rather than hoisted because `wireCompose` returns the chain's concrete composed type — the thing
    /// that lets the terminal read the final box's contents.
    // Scope entry lives in the *terminal*, matching M5.4.3: the scope's lifetime then covers the
    // middleware chain that wraps it, its teardown runs after the response, and a failure entering it is
    // raised where `@ErrorResponse` can still map it. The bound subject reaches the forwarders through
    // the generated task-local.
    let scoped = scopedSubject
    func terminalCall(indent: String) -> String {
        let invoke = """
            \(indent)try await WireOpenAPIRoutes.invoke(
            \(indent)    wireOpenAPIRoute, request: request, pathParameters: parameters,
            \(indent)    reader: reader, sender: sender
            \(indent))
            """
        if perRequestStrategy, let scoped {
            // No ambient state: the subject is constructed, wrapped in a conformer, and that conformer's
            // own handler for this route is resolved by index. `registerHandlers` therefore runs once per
            // request — the cost this strategy trades for the task-local's implicitness.
            return """
                \(indent)let (wireOpenAPISubject, wireOpenAPITeardown) = try await self._wireEnterScope(request)
                \(indent)do {
                \(indent)    let wireOpenAPIConformer = _WireOpenAPIRequest_\(sanitizedKeyFragment(spec))(
                \(indent)        _wireSubject: wireOpenAPISubject
                \(indent)    )
                \(indent)    let wireOpenAPIHandler = try WireOpenAPIRoutes.handler(
                \(indent)        at: wireOpenAPIIndex, of: wireOpenAPIConformer
                \(indent)    )
                \(indent)    try await WireOpenAPIRoutes.invoke(
                \(indent)        handler: wireOpenAPIHandler, request: request, pathParameters: parameters,
                \(indent)        reader: reader, sender: sender
                \(indent)    )
                \(indent)} catch {
                \(indent)    _ = await wireOpenAPITeardown()
                \(indent)    throw error
                \(indent)}
                \(indent)_ = await wireOpenAPITeardown()
                """
        }
        guard let scoped else { return invoke }
        // The subject is bound around the *handler*, not around `invoke`: `withValue` borrows its
        // captures, and `invoke` consumes the `~Copyable` reader and sender. Everything the wrapped
        // handler captures is copyable.
        return """
            \(indent)let (wireOpenAPISubject, wireOpenAPITeardown) = try await self._wireEnterScope(request)
            \(indent)let wireOpenAPIHandler:
            \(indent)    @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
            \(indent)        HTTPResponse, HTTPBody?
            \(indent)    ) = { wireOpenAPIRequest, wireOpenAPIBody, wireOpenAPIMetadata in
            \(indent)        try await Self.$_wireScoped_\(scoped.typeName).withValue(wireOpenAPISubject) {
            \(indent)            try await wireOpenAPIRoute.handler(
            \(indent)                wireOpenAPIRequest, wireOpenAPIBody, wireOpenAPIMetadata
            \(indent)            )
            \(indent)        }
            \(indent)    }
            \(indent)do {
            \(indent)    try await WireOpenAPIRoutes.invoke(
            \(indent)        handler: wireOpenAPIHandler, request: request, pathParameters: parameters,
            \(indent)        reader: reader, sender: sender
            \(indent)    )
            \(indent)} catch {
            \(indent)    _ = await wireOpenAPITeardown()
            \(indent)    throw error
            \(indent)}
            \(indent)_ = await wireOpenAPITeardown()
            """
    }

    func registerBlock(entries: [String], indent: String) -> String {
        guard !entries.isEmpty else {
            return """
                \(indent)builder.register(method: wireOpenAPIRoute.method, path: wireOpenAPIRoute.path) { request, _, parameters, reader, sender in
                \(terminalCall(indent: indent + "    "))
                \(indent)}
                """
        }
        return """
            \(indent)builder.register(method: wireOpenAPIRoute.method, path: wireOpenAPIRoute.path) {
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
            \(terminalCall(indent: indent + "            "))
            \(indent)        }
            \(indent)    }
            \(indent)}
            """
    }

    // With no route-scope middleware every operation takes the same chain, so one register call in the
    // loop suffices. With it, operations differ, and each needs its own fold — hence a switch on the
    // route the document says the operation registers as.
    // Which conformer the bootstrap collection registers against. In the per-request strategy the
    // aggregate deliberately does not conform to `APIProtocol` — the per-request struct does — so the
    // shape is learned from one built with no subject.
    let collectionConformer =
        perRequestStrategy
        ? "_WireOpenAPIRequest_\(sanitizedKeyFragment(spec))(_wireSubject: nil)"
        : "self"
    let registrations: String
    var unmatchedDeclaration = ""
    var unmatchedCheck = ""
    if routeCases.isEmpty {
        registrations = registerBlock(entries: controllerEntries, indent: "            ")
    } else {
        var branches: [String] = []
        for entry in routeCases {
            branches.append("            case (\"\(entry.route.method)\", \"\(entry.route.path)\"):")
            branches.append(
                "                wireOpenAPIUnmatched.remove(\"\(entry.route.method) \(entry.route.path)\")"
            )
            branches.append(registerBlock(entries: controllerEntries + entry.entries, indent: "                "))
        }
        branches.append("            default:")
        branches.append(registerBlock(entries: controllerEntries, indent: "                "))
        let declared = routeCases.map { "\"\($0.route.method) \($0.route.path)\"" }
        registrations = """
                    switch (wireOpenAPIRoute.method.rawValue, wireOpenAPIRoute.path) {
            \(branches.joined(separator: "\n"))
                    }
            """
        // Guard the composition: this package derives the registered path from the document, while the
        // generated `registerHandlers` derives it inside `apiPathComponentsWithServerPrefix`. If those
        // ever disagree the switch quietly takes `default` and the route's middleware vanishes, so the
        // witness fails at startup instead, naming what would have been dropped.
        unmatchedDeclaration = "        var wireOpenAPIUnmatched: Set<String> = [\(declared.joined(separator: ", "))]"
        // The description is written to stderr before the throw. Registration happens after the server is
        // constructed, so an error thrown out of the generated `@main` races the server's teardown — NIO
        // traps on its leaking promise first and the error is never printed. A misconfiguration the
        // developer cannot see is barely better than one that fails silently.
        unmatchedCheck = """
                    if !wireOpenAPIUnmatched.isEmpty {
                        let wireOpenAPIError = WireOpenAPIRoutes.RouteMismatch(
                            operations: wireOpenAPIUnmatched.sorted()
                        )
                        FileHandle.standardError.write(Data((wireOpenAPIError.description + "\\n").utf8))
                        throw wireOpenAPIError
                    }
            """
    }

    // The `APIProtocol` conformance — the aggregate implements every operation and forwards each to the
    // controller that declared it.
    //
    // The aggregate has to be the conformer, not the controller. `registerHandlers` needs a conformer at
    // *registration* time, once at bootstrap, while a `@Scoped(seed:)` controller only exists per
    // request — so there is nothing to register with unless the app-scoped aggregate stands in. That is
    // also what lets several controllers share one spec: each contributes the operations it declares,
    // and the protocol's completeness is checked by the compiler.
    //
    // Input and output types are the spellings the user wrote, copied verbatim, so no operationId is
    // ever transformed into a type name here.
    /// How a forwarder reaches its subject. An app-scoped one is a stored field — singular at one
    /// subject, so a single-controller aggregate emits what `.contributesProxy` always did. A
    /// request-scoped one is read from the task-local the terminal bound.
    func forwarderBody(_ subject: DiscoveredController, _ operation: DiscoveredOperation) -> String {
        let field = controllers.count == 1 ? "_wireSubject" : "_wireSubject_\(subject.typeName)"
        guard subject.seed != nil else {
            return "        try await \(field).\(operation.methodName)(input)"
        }
        return """
                    guard let wireOpenAPISubject = Self._wireScoped_\(subject.typeName) else {
                        throw WireOpenAPIRoutes.OutsideRequest(operation: "\(operation.operationID)")
                    }
                    return try await wireOpenAPISubject.\(operation.methodName)(input)
            """
    }

    var forwarders: [String] = []
    var scopeLocals: [String] = []
    for subject in controllers {
        if subject.seed != nil {
            scopeLocals.append(
                """
                    /// The request-scoped `\(subject.typeName)` for the request being served. The terminal
                    /// enters the scope and binds this; the forwarders below read it. It has to travel this
                    /// way because the generator captures the conformer once, at registration, and offers no
                    /// per-request channel through `registerHandlers`.
                    @TaskLocal static var _wireScoped_\(subject.typeName): \(subject.typeName)?
                """
            )
        }
        for operation in subject.operations {
            forwarders.append(
                """
                    func \(operation.methodName)(_ input: \(operation.inputType)) async throws -> \(operation.outputType) {
                \(forwarderBody(subject, operation))
                    }
                """
            )
        }
    }
    if perRequestStrategy, let scoped = scopedSubject {
        // The per-request conformer. Its subject is optional because the *bootstrap* collection needs a
        // conformer before any request exists — registration only builds closures, never calls them, so a
        // nil subject is never dereferenced there.
        let perRequestForwarders = scoped.operations.map { operation in
            """
                func \(operation.methodName)(_ input: \(operation.inputType)) async throws -> \(operation.outputType) {
                    guard let subject = _wireSubject else {
                        throw WireOpenAPIRoutes.OutsideRequest(operation: "\(operation.operationID)")
                    }
                    return try await subject.\(operation.methodName)(input)
                }
            """
        }
        lines.append(
            """
            struct _WireOpenAPIRequest_\(sanitizedKeyFragment(spec)): APIProtocol, TransportContributor {
                let _wireSubject: \(scoped.typeName)?

                func registerWireHandlers(on transport: any ServerTransport) throws {
                    try registerHandlers(on: transport\(serverURLArgument))
                }

            \(perRequestForwarders.joined(separator: "\n\n"))
            }
            """
        )
        lines.append("")
    }

    if !forwarders.isEmpty, !perRequestStrategy {
        lines.append(
            """
            extension \(proxy) {
            \(scopeLocals.joined(separator: "\n"))
            }
            """
        )
        lines.append("")
        lines.append(
            """
            extension \(proxy): APIProtocol {
            \(forwarders.joined(separator: "\n\n"))
            }
            """
        )
        lines.append("")
    }

    // The shape `registerHandlers` needs. At one subject the aggregate keeps the singular `_wireSubject`
    // field, so the witness delegates to the controller's own generated registration — under the
    // document's own server prefix, which has to be passed explicitly (see `ServerPrefix`).
    // Who conforms to `APIProtocol` decides what this witness can call:
    //   • markers present  → the aggregate conforms, so it registers itself;
    //   • no markers       → the legacy shape, where the single controller is still its own conformer;
    //   • per-request      → the aggregate deliberately does not conform (the per-request struct does),
    //                        and the route path collects through that, so no witness is needed at all.
    if !perRequestStrategy {
        let registrationTarget = forwarders.isEmpty ? "_wireSubject." : ""
        lines.append(
            """
            extension \(proxy): TransportContributor {
                func registerWireHandlers(on transport: any ServerTransport) throws {
                    try \(registrationTarget)registerHandlers(on: transport\(serverURLArgument))
                }
            }
            """
        )
        lines.append("")
    }

    // The conformance the proxy is *collated* as. It delegates to the witness above: the operation set
    // is discovered by running the generator's own registration against a collector, so there is no
    // per-operation codegen here.
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
        \(unmatchedDeclaration)
                for (wireOpenAPIIndex, wireOpenAPIRoute) in try WireOpenAPIRoutes.operations(
                    of: \(collectionConformer)
                ).enumerated() {
        \(registrations)
                }
        \(unmatchedCheck)
            }
        }
        """
    )
    lines.append("")
}

try (lines.joined(separator: "\n")).write(toFile: outputPath, atomically: true, encoding: .utf8)
