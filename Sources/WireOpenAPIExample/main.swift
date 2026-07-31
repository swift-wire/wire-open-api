import HTTPTypes
import WireMVCServerTransport
import WireOpenAPI

// End-to-end: the build plugin collates each spec's `@OpenAPIController`s onto one proxy, contributed
// to `WireMVCKeys.routeContributors` — the same key `@Controller` uses, so in a WireMVC app these serve
// as ordinary routes. Here there is no router, so the example takes the other path:
// serving them on a foreign `ServerTransport` is `WireMVCServerTransport.apply` — the *same* call a
// WireMVC app makes, registering every collated route uniformly. There is no OpenAPI-specific facade:
// one that filtered the route collection by conformance would silently drop `@Controller` routes.
let graph = try await Wire.bootstrap()

let transport = RecordingTransport()
try WireMVCServerTransport.apply(graph, to: transport)

// Two specs → two aggregate proxies → two contributors in the handlers key, each registering its own
// document's operations.
let recorded = transport.registered.withLock { $0 }.sorted { $0.path < $1.path }
precondition(recorded.count == 2, "expected 2 registered operations, got \(recorded.count)")
precondition(
    recorded[0].method == .get && recorded[0].path == "/ping",
    "unexpected registration: \(recorded)"
)
precondition(
    recorded[1].method == .get && recorded[1].path == "/pong",
    "unexpected registration: \(recorded)"
)

print("wire-open-api OK — two specs collated as RouteContributors and applied to a ServerTransport")
