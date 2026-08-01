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

See [swift-wire's WireOpenAPIDesign.md](https://github.com/tachyonics/swift-wire/blob/main/Documentation/Notes/WireOpenAPIDesign.md)
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
onto **one** proxy: a document's operations are implemented against one generated
`APIProtocol`, so one conformer per spec mounts each operation exactly once. An app serving
several documents names them:

```swift
@Singleton @OpenAPIController(spec: "TaskAPI")
struct TaskController: APIProtocol { … }
```

With a single spec the bare `@OpenAPIController` groups everything together. There is no
base-path argument: the prefix belongs to the document's `servers:` block, applied by the
runtime's own `apiPathComponentsWithServerPrefix`.

Splitting one spec across several controllers is rejected for now. Per-operation dispatch
removes the reason it was ever a constraint, but the conformer still holds a single
subject; lifting it is the remaining M6d work.

## Requires a forked swift-openapi-generator, for now

Operations are dispatched by calling the generated per-operation method on a
`UniversalServer` built for the request. Stock swift-openapi-generator emits that extension
`fileprivate`, so it needs a one-line change (`ServerTranslator.swift`,
`accessModifier: .fileprivate` → `nil`) — `internal` is sufficient, because `WireOpenAPIGen`
emits into the same module. Until that lands upstream, consumers point at
[the fork](https://github.com/tachyonics/swift-openapi-generator/tree/swift-wire).

The alternative is to keep one registration and reach the request's subject through a
task-local, which works on a stock generator. It measured equal at p50 and worse in mean
and p99, and it costs the whole collecting-transport machinery, so main does not carry it —
see the `m6d-request-scope-strategies` branch.

## Status

M3 complete; M6d (advanced OpenAPI integration) in progress.

- **M3.1–M3.3** — the `ServerTransport` collation surface, the `@OpenAPIController` macro,
  and a framework-free end-to-end example. **Done.**
- **M6d.0b** — the proxy cutover: adapter-owned build plugin, aggregate proxy per spec,
  macro demoted to a marker. **Current.**
- Next: OpenAPI operations mounted as WireMVC routes, so middleware, error tiers and the
  composition root are shared with annotation-driven routes.

Depends on pushed swift-wire `main`; validated on macOS and Linux (see CI).
