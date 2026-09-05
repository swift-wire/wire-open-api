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

See [WireOpenAPIDesign.md](Documentation/Notes/WireOpenAPIDesign.md) for the full design.

## Installation

A consumer depends on **both** `WireOpenAPI` and `WireMVC`, and applies
`WireOpenAPIBuildPlugin` rather than swift-wire's `WireBuildPlugin` — the adapter's plugin runs
`WireGen` for the graph and `WireOpenAPIGen` for the route witnesses over one source set.

```swift
.executableTarget(
    name: "App",
    dependencies: [
        .product(name: "WireOpenAPI", package: "wire-open-api"),
        .product(name: "WireMVC", package: "wire-mvc"),
        .product(name: "Wire", package: "swift-wire"),
    ],
    plugins: [.plugin(name: "WireOpenAPIBuildPlugin", package: "wire-open-api")]
)
```

```swift
@Singleton
@OpenAPIController
struct TaskController: APIProtocol {
    @Inject var repository: TaskRepository

    @Operation
    func getTask(@Path id: String) async throws -> Task { try repository.find(id) }
}
```

Requires a Swift 6.4 toolchain, and targets macOS 26 and Linux. The generator build it is
compiled against is tracked in
[#50](https://github.com/tachyonics/wire-open-api/issues/50).

## Documentation

The user-facing documentation is a DocC catalog — build it with
`swift package generate-documentation --target WireOpenAPI`, or read the articles under
[`Sources/WireOpenAPI/WireOpenAPI.docc`](Sources/WireOpenAPI/WireOpenAPI.docc):

- **Getting started** — adding the package, writing a controller, and the two ways to implement
  an operation.
- **Documents** — several controllers sharing one spec, and several specs in one app.
- **Serving** — the one call that serves them, and where a request-scoped controller's errors are
  mapped.
- **Constraints** — the state of schema validation.

Design notes recording *why* each decision was made are in
[`Documentation/Notes`](Documentation/Notes); proposals not yet built are in
[`Proposals`](Proposals).

## Contributing

Building, testing and the documentation gate are in [CONTRIBUTING.md](CONTRIBUTING.md).

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
