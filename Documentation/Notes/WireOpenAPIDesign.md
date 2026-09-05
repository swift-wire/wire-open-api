# WireOpenAPI — design note (M3)

> **Status:** the model for M3, the second framework adapter. It **re-homes
> WireHummingbird's collation model** ([WireHummingbirdDesign.md](https://github.com/swift-wire/swift-wire/blob/main/Documentation/Notes/WireHummingbirdDesign.md))
> from `some RouterMethods<Context>` onto `some ServerTransport`, and in doing so
> establishes the **cross-runtime collation surface** that WireMVC (M5) later folds
> into. This note **supersedes the `@RoutedBy` / `_wireRegister` model** the roadmap
> and [AdapterModel.md](https://github.com/swift-wire/swift-wire/blob/main/Documentation/Notes/AdapterModel.md) still carry — that was the post-construction
> side-effect *sink* (`_wireRegister(instance:, transport:)` emitted after graph
> build), retired in M2.3 when collation replaced it. M3 is collation, like M2.
>
> **Superseded in part by M6d** — [WireOpenAPIAdvanced.md](WireOpenAPIAdvanced.md),
> which is built and merged. Read that note first for anything about *how operations
> are mounted*: M6d retires `TransportKeys.handlers` as a collated key, so
> `@OpenAPIController` contributes to `WireMVCKeys.routeContributors` and operations
> register individually rather than through `registerHandlers`. It settles three
> deferrals this note names — request-scoped controllers, per-controller middleware,
> and `registerHandlers(configuration:)`. The last dissolved rather than shipped:
> coding turned out to be a WireMVC concern, because a `@Get` route asks the same
> question and was answering it differently.
>
> What stands unchanged is *why the adapter targets `ServerTransport`*, and the
> cross-runtime argument for it — M6d builds on that rather than replacing it. The
> **WireMVC seam** section below asked for the single collation surface M6d then
> delivered.

## What M3 is

A **cross-runtime framework adapter**: auto-wire an app's OpenAPI controllers —
types conforming to the generated `APIProtocol` — onto a `some ServerTransport`,
constructing each from Wire's graph. The forcing case is task-cluster: its
hand-written

```swift
let taskController = TaskController(repository: repository)   // TaskController: APIProtocol
try taskController.registerHandlers(on: router)              // router is a ServerTransport via OpenAPIHummingbird
```

becomes wired collation. WireOpenAPI does **not** abstract routes — routing is
**spec-driven** (the OpenAPI document is the source of truth; `registerHandlers` is
generated). Declarative `@Get`/`@Post` routing is WireMVC (M5), which shares this
adapter's surface (see *The WireMVC seam*).

**App-scoped only**, same as WireHummingbird — request-scoped controllers need
request-scope entry, which is M5.

## Why this is the cross-runtime adapter

`ServerTransport` (from `OpenAPIRuntime`) is the OpenAPI generator's transport
seam — it already has Hummingbird, Vapor, and Lambda adapters
(`swift-openapi-hummingbird`, `-vapor`, `-lambda`). A controller mounted onto
`some ServerTransport` runs on **any** of them unchanged. That is the property
WireHummingbird's native surface can't have: `RouterMethods<Context>` handlers
receive the app's real per-request context, which is Hummingbird-specific and can't
be synthesised from a context-free transport (the one-way bridge argued in
WireHummingbirdDesign's *Native vs cross-runtime surfaces* — native→transport works,
transport→native is semantically impossible). WireOpenAPI sits on the transport
side of that line, and inherits the portability.

Two structural consequences make the cross-runtime property real rather than
asserted:

- **WireOpenAPI depends only on `OpenAPIRuntime`.** `ServerTransport` and
  `APIProtocol` both live there; the adapter never imports Hummingbird, Vapor, or
  any HTTP framework. WireHummingbird *had* to depend on Hummingbird — its surface
  names `RouterMethods`. WireOpenAPI names only `ServerTransport`, so it stays
  runtime-agnostic at the package level. The consuming app picks the transport
  adapter (`OpenAPIHummingbird` / `-vapor` / `-lambda`); WireOpenAPI never sees it.
- **The collation surface needs no generic witness.** WireHummingbird's
  `RouteContributor.addWireRoutes<Context>` is a *generic method* precisely because
  `RouterMethods<Context>` has a free `Context` that binds at the `apply` call.
  `ServerTransport` carries no free type — it is context-free by construction — so
  the contributor witness is a plain method. The context-freeness WireHummingbird
  had to engineer around is native here.

## The architecture

### Transport outside the graph; the graph collates handlers

A straight re-home of WireHummingbird's *router-outside-the-graph*: the
`ServerTransport` is a bootstrap collaborator that stays **outside** the graph. The
graph only collates handler contributions; a facade applies them to a
user-provided transport. Nothing in the graph consumes a mutated collaborator, so
ordering never arises.

- **Handlers → a `CollectedKey`.** An `@OpenAPIController` type `@Contributes` into
  `TransportKeys.handlers = CollectedKey<any TransportContributor>`. Each handler
  registers its own operations as a side effect (`registerHandlers`), so it can't
  fold to a value — hence `CollectedKey`, exactly as HB routes.
- **No services, no lifecycle.** Unlike Hummingbird, **OpenAPI is not a runtime** —
  it's a transport-registration surface over whatever runtime the app already runs.
  So WireOpenAPI collates handlers *only*; services and `ServiceGroup` lifecycle
  stay with WireHummingbird (or the app). The two adapters coexist on one graph
  (below).

### The collation surface

```swift
import OpenAPIRuntime
import Wire

/// A transport contributor. `registerWireHandlers` is generated by
/// `@OpenAPIController` — it owns the mount (the optional base path) and delegates
/// to the generated `registerHandlers(on:)`. Not written by hand (the `Wire` in the
/// name marks it generated).
public protocol TransportContributor {
    func registerWireHandlers(on transport: any ServerTransport) throws
}

public enum TransportKeys {}

extension TransportKeys {
    /// Handlers `@OpenAPIController` aliases into.
    public static let handlers = CollectedKey<any TransportContributor>()
}
```

The witness takes `any ServerTransport` — matching the generated
`registerHandlers(on: any ServerTransport, …)` signature, and needing no generic
method because there is no context to defer.

### The `@OpenAPIController` macro

A **conformance-extension macro** (the same shape as `@HummingbirdController`): the
controller keeps its native `APIProtocol` conformance and its handler methods
(`createTask`, `getTask`, …) untouched; the macro generates the `TransportContributor`
conformance whose witness calls the generated `registerHandlers`.

```swift
@Singleton
@Contributes(to: TransportKeys.handlers)
@OpenAPIController                          // no-arg → mount at the spec's default serverURL
struct TaskController<Repository: TaskRepository>: APIProtocol {
    @Inject init(repository: Repository) { self.repository = repository }
    // createTask / getTask / … unchanged
}
// generated:
extension TaskController: TransportContributor {
    func registerWireHandlers(on transport: any ServerTransport) throws {
        try registerHandlers(on: transport)
    }
}
```

**The optional path parameter** mirrors `@HummingbirdController("path")`. Where
`@HummingbirdController` maps its path to `router.group(path)`, `@OpenAPIController` maps
its path to `registerHandlers`'s **`serverURL`** — the base URL against which all of
the spec's operation paths are relative, so a path prefix is the transport-side
equivalent of a route group:

```swift
@OpenAPIController("/api/v1")
// generated witness:
//   try registerHandlers(on: transport, serverURL: <URL from "/api/v1">)
```

No-arg uses `registerHandlers`'s default (`.defaultOpenAPIServerURL`). The exact
URL construction from the path string (a validating initialiser vs a literal) is an
M3.2 implementation detail; the surface is: *path in → `serverURL` out*.

`registerHandlers` also takes `configuration:` and `middlewares:`. Both are
**deferred** and neither is a parameter on `@OpenAPIController`:

- **Configuration** becomes its own annotation, **`@OpenAPIConfiguration`**, when a
  use case forces it — keeping `@OpenAPIController` to the one thing it does. Not in
  M3.
- **Middlewares** align with **M5**: the ecosystem-standard, proposed `Middleware`
  (`swift-http-api-proposal`) that WireMVC targets. WireOpenAPI doesn't invent a
  parallel middleware surface; it waits for the M5 shape. Not in M3.

### The `@Contributes` alias

```swift
public let wireOpenAPIControllerAlias = WireAdapterAnnotationV1(
    annotation: "OpenAPIController",
    capability: .contributes(to: TransportKeys.handlers)
)
```

So `@Singleton @OpenAPIController` is all a controller needs — the plugin injects
the synthetic `@Contributes(to: TransportKeys.handlers)` (the explicit `@Contributes`
above is shown for clarity; the alias makes it implicit, exactly as with
`@HummingbirdController`).

### Graph conformance — reuses the shipped Core capability

WireOpenAPI declares the composable surface and the graph-conformance mapping; Wire
Core emits `extension _WireGraph: TransportComposable` knowing nothing about OpenAPI
or HTTP. The composable is named for the surface, not the package (`Transport`, not
`WireOpenAPI`) — it is part of the shared cross-runtime surface M5 folds into, so
its name shouldn't imply OpenAPI ownership:

```swift
public protocol TransportComposable {
    var handlers: [any TransportContributor] { get }
}

public let wireTransportConformance = WireGraphConformanceV1(
    conformsTo: (any TransportComposable).self,
    members: [.init("handlers", from: TransportKeys.handlers)]
)
```

`handlers` maps a `CollectedKey` product to `[any TransportContributor]` — the same
**non-associated-type** case the shipped emission (M2.1) already handles for HB's
`routes`. **The M3.1 gate is confirming Wire Core needs no change**; the mechanism
was proven by spike-10 and the wire-hummingbird repo, so a change would be a
surprise, not the expectation.

### Entry: `Wire.bootstrap()` + `WireOpenAPI.apply(_:to:)`

```swift
public enum WireOpenAPI {
    /// Register the graph's collated OpenAPI controllers onto a user-owned
    /// transport (a Hummingbird `Router`, a Vapor `Application`, a Lambda
    /// transport — any `ServerTransport`). Throws what `registerHandlers` throws.
    public static func apply(
        _ graph: some TransportComposable,
        to transport: some ServerTransport
    ) throws {
        for contributor in graph.handlers {
            try contributor.registerWireHandlers(on: transport)
        }
    }
}
```

The migrated task-cluster `buildRouter`:

```swift
let graph = try await Wire.bootstrap()               // concrete _WireGraph
let router = Router(context: AppRequestContext.self)
router.addMiddleware { LogRequestsMiddleware(.info) }
router.get("/") { _, _ in "task-cluster is running" }
try WireOpenAPI.apply(graph, to: router)             // registerHandlers for each collated controller
return Application(router: router, …)
```

`apply` throws (where WireHummingbird's doesn't), because `registerHandlers` throws.

### Coexistence with WireHummingbird on one graph

The concrete `_WireGraph` conforms to **every** declared adapter protocol, so an app
can run both adapters against the same graph and the same router: WireHummingbird
supplies services/lifecycle and any native root routes; WireOpenAPI supplies the
transport handlers. This is exactly task-cluster's shape — the manual `router.get("/")`
and `LogRequestsMiddleware` stay app-owned, the OpenAPI controllers collate.

```swift
let graph = try await Wire.bootstrap()
let services = WireHummingbird.apply(graph, to: router)   // services + any native routes
try WireOpenAPI.apply(graph, to: router)                  // OpenAPI transport handlers
return Application(router: router, services: services, …)
```

## The WireMVC seam (M5)

> **Superseded by M6d — the fold happened, in the other direction.** This section's *intent* held: one
> collation surface, both annotations landing in the same key, a re-home rather than a parallel surface.
> Its *choice of base* did not. M5 declared `WireMVCKeys.routeContributors` instead of re-homing into
> `TransportKeys.handlers`, because its witness targets the route builder rather than
> `some ServerTransport` — so the parallel surface this section wrote to avoid is what shipped. M6d
> resolves it by folding the other way: `@OpenAPIController` contributes to
> `WireMVCKeys.routeContributors`, and `TransportKeys.handlers` / `TransportComposable` retire as
> collated surfaces. `TransportContributor` survives as plumbing — it is exactly the shape
> `registerHandlers` needs — but is no longer a collated key.
>
> **`WireOpenAPI.apply(_:to:)` (below) retires with them.** Serving the collated operations on a foreign
> `some ServerTransport` is `WireMVCServerTransport.apply(graph, to: transport)` — the same call a
> WireMVC app already makes, registering every collated route uniformly. An adapter-specific facade
> cannot survive the fold: after it, the graph's collection holds *all* routes, so such a facade would
> have to filter by conformance — silently dropping the app's `@Controller` routes, and
> double-registering if used alongside the correct call. The sections below describing `apply` are
> M3-historical.
>
> The base was wrong for historical rather than analytical reasons: when M3 shipped, `some
> ServerTransport` was the only cross-runtime target available. The proposal server became usable at M5,
> and the two surfaces turned out to be inter-convertible — `WireMVCServerTransport` carries routes out
> onto a transport, and M6d's collecting transport carries transport registrations in as routes. Given
> the choice, the route surface is the richer one (streaming primitives, matched path parameters,
> per-route middleware folding) and the one every routing feature attaches to (`@NotFound`,
> `@ErrorResponse` tiers, the global middleware layer, `@WireMVCBootstrap`). See
> [WireOpenAPIAdvanced.md](WireOpenAPIAdvanced.md), *One collation surface*.

The durable, cross-runtime primitive this milestone establishes is the
**`ServerTransport` collation surface** — `TransportContributor`,
`TransportKeys.handlers`, `TransportComposable` + its conformance declaration, and
`apply(_:to: some ServerTransport)` — **not the `@OpenAPIController` annotation**.
WireOpenAPI owns only the annotation and its macro; everything else is the surface.
There are two sources of routing truth that both mount on a transport:

| | routing source | witness body |
|---|---|---|
| **`@OpenAPIController`** (M3) | the OpenAPI spec | `try registerHandlers(on:)` |
| **`@Controller` + `@Get`/`@Post`** (M5, WireMVC) | Swift-declared | generated route registration |

Both produce `TransportContributor`s into the *same* `handlers` key. Crucially, M5's
controllers `@Contributes(to: TransportKeys.handlers)` — the **same key** — so they
land in the **same `graph.handlers` collection** through the **single existing
conformance declaration**, and the **same `apply`** picks them up. WireMVC declares
**no second conformance** (two adapters both emitting `extension _WireGraph:
TransportComposable` would collide); it only adds its annotation + macro. So M5's
`@Controller` is a **re-home onto this surface, not a new parallel one** — the
resolution WireHummingbirdDesign's *Adapter-collection consolidation* open item asked
for ("keep each contributor shaped around the target it registers on … so any fold-in
is a re-home, not a rewrite"). The two distinct annotation names keep the two routing
models legible instead of hiding them behind one mode-detecting macro.

Where the shared surface **physically lives** is an M5-time decision: it starts in
`WireOpenAPI` and extracts into a small shared module (`WireTransport`, or Wire Core)
when WireMVC actually needs to depend on it. YAGNI until then — WireMVC is the second
consumer that forces the extraction.

## Package structure

`wire-open-api` mirrors `wire-hummingbird`'s layout: a `WireOpenAPI` library, a
`WireOpenAPIMacros` macro target, a `WireOpenAPIExample`, tests, a presence-only
`_WireExports.swift` marker (so a consuming target's plugin re-parses the sources for
the key + conformance declaration), and its own macOS + Linux CI. Dependencies:
`OpenAPIRuntime` and pushed swift-wire main — **no HTTP framework**.

## Suggested sequencing

- **M3.1 — the shared `ServerTransport` collation surface.** `TransportContributor`,
  `TransportKeys.handlers`, `TransportComposable`, the `WireGraphConformanceV1`
  declaration, `WireOpenAPI.apply`, `_WireExports.swift`. Gate: confirm Wire Core
  needs no change.
- **M3.2 — the `@OpenAPIController` macro + alias.** Conformance-extension macro
  (no-arg and `("path")` forms), witness calling `registerHandlers`, the
  `WireAdapterAnnotationV1` alias. Pin the path→`serverURL` URL construction here.
- **M3.3 — migrate task-cluster.** `TaskController` gains `@Singleton` +
  `@Inject init(repository:)` + `@OpenAPIController`; `buildRouter` switches to
  `WireOpenAPI.apply(graph, to: router)`. Validate against pushed swift-wire main
  (`swift package update`).
- **M3.4 — the cross-runtime proof.** Mount the same graph on a second
  `ServerTransport` (`OpenAPIVapor` or a Lambda transport) in an example/test — the
  headline differentiator made concrete.
- **M3.5 — docs.** This note; the `ROADMAP.md` M3 rewrite (retire
  `@RoutedBy`/`_wireRegister`); refresh `AdapterModel.md`'s worked example onto
  `@OpenAPIController`.

## References

- [WireHummingbirdDesign.md](https://github.com/swift-wire/swift-wire/blob/main/Documentation/Notes/WireHummingbirdDesign.md) — the collation model this
  re-homes; *Native vs cross-runtime surfaces* (the ServerTransport line);
  *Adapter-collection consolidation* (the M5 fold-in this note answers).
- [AdapterModel.md](https://github.com/swift-wire/swift-wire/blob/main/Documentation/Notes/AdapterModel.md) — the contribution-alias contract
  (`WireAdapterAnnotationV1`); its `@RoutedBy` / `_wireRegister` example is
  superseded by this note.
- `wire-hummingbird` (external repo) — the shipped surface this mirrors
  (`HummingbirdRoute.swift`, `WireHummingbird.swift`, `_WireExports.swift`).
- `spike-10` — graph
  conformance emission (the M3.1 no-Core-change basis).
