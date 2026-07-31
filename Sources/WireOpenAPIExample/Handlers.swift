import HTTPTypes
import OpenAPIRuntime
import Synchronization
import Wire
import WireOpenAPI

// A framework-free `ServerTransport` that records the (method, path) of every registered
// operation — enough to prove the collation surface applies handlers to a real transport
// without pulling in an HTTP framework.
final class RecordingTransport: ServerTransport {
    let registered = Mutex<[(method: HTTPRequest.Method, path: String)]>([])

    func register(
        _ handler:
            @Sendable @escaping (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
                HTTPResponse, HTTPBody?
            ),
        method: HTTPRequest.Method,
        path: String
    ) throws {
        registered.withLock { $0.append((method: method, path: path)) }
    }
}

// Stand-in for the swift-openapi-generated `APIProtocol` and its `registerHandlers` extension,
// so the example exercises `@OpenAPIController` end-to-end without running the OpenAPI
// generator. A real app gets these from the generator's build plugin; here the registration is
// hard-coded to one operation.
protocol APIProtocol {}

extension APIProtocol {
    func registerHandlers(on transport: any ServerTransport) throws {
        try transport.register(
            { _, _, _ in (HTTPResponse(status: .ok), nil) },
            method: .get,
            path: "/ping"
        )
    }
}

// A controller in its natural OpenAPI shape: an `APIProtocol` conformer with `@Inject`ed deps.
// `@Singleton` makes it a binding; `@OpenAPIController` is a marker directing the plugin to collate it
// onto the aggregate proxy for its spec — the proxy, not the controller, carries the generated
// `TransportContributor` witness and is what contributes to `TransportKeys.handlers`.
@Singleton
@OpenAPIController(spec: "First")
struct PingController: APIProtocol {
    @Inject init() {}
}

// A SECOND spec. Two documents mean two generated `APIProtocol`s, so `spec:` names which one a
// controller implements — grouping the aggregate proxies (`_WireOpenAPIContributor_First` /
// `_WireOpenAPIContributor_Second`) rather than collapsing both onto one. It has to be declared at the
// use site: a spec's generated types and the controllers implementing it routinely live in different
// modules, so it cannot be inferred from where the controller sits.
protocol SecondAPIProtocol {}

extension SecondAPIProtocol {
    func registerHandlers(on transport: any ServerTransport) throws {
        try transport.register(
            { _, _, _ in (HTTPResponse(status: .ok), nil) },
            method: .get,
            path: "/pong"
        )
    }
}

@Singleton
@OpenAPIController(spec: "Second")
struct PongController: SecondAPIProtocol {
    @Inject init() {}
}
