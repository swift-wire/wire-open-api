# wire-open-api

`WireOpenAPI` — a cross-runtime [swift-wire](https://github.com/tachyonics/swift-wire)
adapter for [swift-openapi-generator](https://github.com/apple/swift-openapi-generator).

It collates `@OpenAPIController` controllers (types conforming to the generated
`APIProtocol`) onto one generated proxy per spec, has Wire emit a `TransportComposable`
conformance on the generated graph, and registers the collated handlers onto a user-owned
`some ServerTransport` that stays *outside* the graph. Because the target is
`ServerTransport` — and the package depends only on `OpenAPIRuntime`, no HTTP framework —
the same wired controller mounts on Hummingbird, Vapor, or Lambda unchanged.

Handlers-only: unlike a native-framework adapter, OpenAPI is a transport surface, not a
runtime, so services and lifecycle stay with the runtime's own adapter. The two coexist
on one graph.

See [swift-wire's WireOpenAPIDesign.md](https://github.com/tachyonics/swift-wire/blob/main/Documentation/Notes/WireOpenAPIDesign.md)
for the full design.

## Consumers apply `WireOpenAPIBuildPlugin`

Not swift-wire's `WireBuildPlugin`. The adapter's plugin runs both tools over one source
set: `WireGen` for the graph and the contributor-proxy structs, then `WireOpenAPIGen` for
those proxies' `TransportContributor` witnesses.

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
onto **one** proxy, because the generator emits `registerHandlers` once per document and
registers every operation from a single handler — so one conformer per spec is the only
shape that registers each operation once. An app serving several documents names them:

```swift
@Singleton @OpenAPIController(spec: "TaskAPI")
struct TaskController: APIProtocol { … }
```

With a single spec the bare `@OpenAPIController` groups everything together. There is no
base-path argument: the prefix belongs to the document's `servers:` block, which
`registerHandlers` already reads.

Splitting one spec across several controllers is rejected for now — it needs the proxy to
implement `APIProtocol` and dispatch per operation, which is later M6d work.

## Status

M3 complete; M6d (advanced OpenAPI integration) in progress.

- **M3.1–M3.3** — the `ServerTransport` collation surface, the `@OpenAPIController` macro,
  and a framework-free end-to-end example. **Done.**
- **M6d.0b** — the proxy cutover: adapter-owned build plugin, aggregate proxy per spec,
  macro demoted to a marker. **Current.**
- Next: OpenAPI operations mounted as WireMVC routes, so middleware, error tiers and the
  composition root are shared with annotation-driven routes.

Depends on pushed swift-wire `main`; validated on macOS and Linux (see CI).
