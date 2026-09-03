# wire-open-api

`WireOpenAPI` — a cross-runtime [swift-wire](https://github.com/tachyonics/swift-wire)
adapter for [swift-openapi-generator](https://github.com/apple/swift-openapi-generator).

It collates `@OpenAPIController` controllers (types conforming to the generated
`APIProtocol`) onto one generated proxy per spec, contributed to
**`WireMVCKeys.routeContributors`** — the same key `@Controller` uses. An OpenAPI operation is
therefore a route like any other: it serves under the same router, `@NotFound` fallback,
`@ErrorResponse` tiers, global middleware layer and `@WireMVCBootstrap` composition root as an
annotation-driven `@Get`. One routing model, not two.

Serving on Hummingbird, Vapor or Lambda is `WireMVCServerTransport.apply(graph, to: transport)`
— the same call a WireMVC app already makes, registering every collated route uniformly. There
is deliberately no WireOpenAPI-specific facade: one would have to filter the route collection by
conformance, silently dropping the app's `@Controller` routes, and would double-register if used
alongside the correct call.

Handlers-only: unlike a native-framework adapter, OpenAPI is a transport surface, not a
runtime, so services and lifecycle stay with the runtime's own adapter. The two coexist
on one graph.

A consumer depends on **both** `WireOpenAPI` and `WireMVC` directly — Wire activates a
dependency's keys only when it is a direct dependency, and the collation key is WireMVC's.

See [swift-wire's WireOpenAPIDesign.md](Documentation/Notes/WireOpenAPIDesign.md)
for the full design.

## Consumers apply `WireOpenAPIBuildPlugin`

Not swift-wire's `WireBuildPlugin`. The adapter's plugin runs both tools over one source
set: `WireGen` for the graph and the contributor-proxy structs, then `WireOpenAPIGen` for
those proxies' `RouteContributor` witnesses.

```swift
.executableTarget(
    name: "App",
    dependencies: [
        .product(name: "WireOpenAPI", package: "wire-open-api"),
        .product(name: "Wire", package: "swift-wire"),
    ],
    plugins: [.plugin(name: "WireOpenAPIBuildPlugin", package: "wire-open-api")]
)
```

`@OpenAPIController` is a marker; it generates nothing. Controllers sharing a spec collate
onto **one** proxy, because a document's operations are implemented against one generated
`APIProtocol`. An app serving several documents names them:

```swift
@Singleton @OpenAPIController(spec: "TaskAPI")
struct TaskController: APIProtocol { … }
```

With a single spec the bare `@OpenAPIController` groups everything together. There is no
base-path argument: the prefix belongs to the document's `servers:` block, applied by the
runtime's own `apiPathComponentsWithServerPrefix`.

### Several controllers may share one spec

A document does not have to be one object's to serve. Operations are mounted individually,
so each controller contributes the `@RawOperation`s it declares and the proxy holds them
all; `APIProtocol` conformance is what makes the compiler check the set adds up. Declaring
the same `operationId` twice is an error — one operation is mounted once.

Scope and middleware stay per controller, not per spec:

```swift
@Scoped(seed: HTTPRequest.self)
@OpenAPIController(spec: "TaskAPI")
@Middleware(RequireAPIKeyKeys.factory)
struct TaskController { @RawOperation func getTask(…) … }

@Singleton
@OpenAPIController(spec: "TaskAPI")
struct TaskListController { @RawOperation func listTasks(…) … }
```

`getTask` enters a request scope and folds `RequireAPIKey` around itself; `listTasks`, on
the same document, does neither. A request enters only the scope of the controller owning
the operation it dispatches, so nothing is built that the request does not use.

**A scope that refuses is answered by the controller's `@ErrorResponse`.** Entering the scope
happens in the route terminal rather than in the generated forwarder — the entry is what produces
the subject the forwarder is built around, and the scope has to outlive the response so teardown
runs after it — so a `@Scoped(seed:)` binding that throws is outside every `catch` the forwarder
emits. The terminal branches on that failure and answers it with the mappings written on the
controller:

```swift
@Scoped(seed: HTTPRequest.self)
@OpenAPIController()
@ErrorResponse(Unauthenticated.self, .unauthorized, { _ in Problem(message: "no user") })
struct GatedTaskController {
    @Inject let gate: RequestGate   // throws while the scope is built
    @Operation func gatedTask(@Path id: String) async throws -> Task { … }
}
```

Controller scope is the only scope this can be written at: one entry serves every operation the
controller implements, so a failure entering it is not attributable to any one of them. The
existing rule that a controller-scope mapping's status must be declared by every operation is what
makes the answer one the document describes whichever operation was asked for — and for a scoped
controller that now holds even where an operation maps the same error itself, since scope entry
precedes dispatch and the shadowing forwarder never runs.

### Several specs in one app

One document per target, so a second document lives in its own module — its `openapi.yaml`,
the types swift-openapi-generator makes from it, and the controllers implementing them:

```swift
.target(
    name: "OrdersAPI",
    dependencies: [.product(name: "WireOpenAPI", package: "wire-open-api"), …],
    plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
)
```

That module needs `accessModifier: public` in its generator config and a
dependency on the `Wire` product; the app depends on it, and `@OpenAPIController(spec: "OrdersAPI")`
names it. WireGen still runs once, in the app, so that is where the proxy is emitted.

The two forms mean one thing each. Bare `@OpenAPIController()` is **this target's own
document**; `@OpenAPIController(spec: "M")` says the generated `APIProtocol` is module `M`'s.
A `spec:` naming no such dependency is an error rather than a label quietly resolved against
the local document — controllers implementing a document routinely live in a different module
from it, so where a controller is declared says nothing about which document it implements,
and a wrong guess would report itself as a missing `@RawOperation` for operations nobody
wrote.

The hazard this arrangement carries is that the generator names its types from nothing about
the document: **every** spec module spells them `APIProtocol`, `Operations`, `Servers`,
`Components`. In the app, which imports two of them, a bare `Operations.GetOrder.Input` is
"ambiguous for type lookup" — including the spellings copied verbatim out of a controller
that was perfectly unambiguous where it was written. The generated conformer is therefore
emitted inside a per-spec namespace whose typealiases resolve it:

```swift
enum _WireOpenAPISpec_OrdersAPI {
    typealias Operations = OrdersAPI.Operations
    …
    struct Conformer: APIProtocol { … }
}
```

So a controller writes its own spec's types however it likes, qualified or not. An app may
also generate one document itself and import another, because a module's own declarations
win over identically-spelled imported ones.

## Requires a forked swift-openapi-generator, for now

Operations are dispatched by calling the generated per-operation method on a
`UniversalServer` built for the request — the only place an operation's deserializer and
serializer exist, so dispatching one operation rather than registering a whole document
requires reaching it. Stock swift-openapi-generator makes that impossible, and the
[fork](https://github.com/tachyonics/swift-openapi-generator/tree/swift-wire) carries two
small changes:

- the `UniversalServer` extension is no longer `fileprivate`, so other generated code in the
  same module can call it;
- its methods follow the configured `accessModifier:` rather than being internal regardless,
  as `registerHandlers` in the same file already does — which is what a spec in its own
  module needs, since its caller is in another module.

Because those methods extend `UniversalServer`, which is `@_spi(Generated)`, they stay SPI
however public they are declared; the emitted file imports a spec module the same way.

The alternative is to keep one registration and reach the request's subject through a
task-local, which works on a stock generator. It measured equal at p50 and worse in mean
and p99, and it costs the whole collecting-transport machinery, so main does not carry it —
see the `m6d-request-scope-strategies` branch.

## Status

Built. The adapter carries three layers, all shipped. Known gaps and deferrals are tracked as
[issues](https://github.com/tachyonics/wire-open-api/issues), which are the source of truth for status —
notably [#49](https://github.com/tachyonics/wire-open-api/issues/49): schema validation is written and
tested but no codegen reaches it.


- **The `ServerTransport` collation surface**, the `@OpenAPIController` macro, and a
  framework-free end-to-end example.
- **The proxy cutover** — an adapter-owned build plugin, one aggregate proxy per spec, and
  the macro demoted to a marker.
- **Operations mounted as WireMVC routes.** An `@Operation` contributes to
  `WireMVCKeys.routeContributors` exactly as a `@Get` route does, so middleware, error tiers,
  request scope, encoding and the composition root are expressed identically whether a route
  came from an OpenAPI document or from an annotation. There is one routing model, not two.

Depends on pushed swift-wire `main`; validated on macOS and Linux (see CI).
