# Advanced OpenAPI integration — design note (M6d)

> **Status: decision record.** M6d is built. **M6d.0 through M6d.6 are implemented and merged** in
> `wire-open-api`, served over real HTTP by its `Fixtures` package and exercised by a CI script that
> probes a running app rather than asserting generated text. Three things are deferred by decision, not
> left undone: `@OpenAPIConfiguration` (see *Middleware, errors, configuration*), the
> decomposition-transformer registry (see *The typed shim*), and non-JSON bodies at the terminal. One
> thing is genuinely outstanding: **task-cluster is not migrated**, so the forcing case this design was
> chosen for still runs on M3's adapter.
>
> The M6d.0 gate was run on Swift 6.3.3 and the 6.4 snapshot, swift-openapi-generator 1.x, macOS —
> `spike-28`; results and the three
> findings that shaped this note are in *Spike results*.
>
> **How to read it.** Where building changed a decision the original reasoning is kept and marked rather
> than rewritten, so the note records what was believed as well as what is true. Sections carrying a
> *Superseded* or *overtaken* note are the ones to read first. Four decisions moved under contact with a
> compiler or a load generator:
>
> | decision | designed as | settled as | what moved it |
> |---|---|---|---|
> | request scope | task-local around `registerHandlers` | direct dispatch on a copied `UniversalServer` | measurement — and a hoisted `Converter` |
> | conformers per spec | one, believed forced | many, and many specs per app | operations mount individually |
> | reading the document | a dictionary walk over Yams | OpenAPIKit, fully dereferenced | `$ref` parameters were silently dropped |
> | coding settings | an OpenAPI-only attribute | wire-mvc's `WireMVCCoding`, keyed by `BindingKey` | a `@Get` route has the same question |
>
> **The objective is one routing model, not two.** An app should express middleware, error mapping,
> request scope and its composition root the same way whether a route came from an OpenAPI document
> or from `@Get`/`@Post`. That objective — not "typed handlers" — is what selects the architecture
> below: OpenAPI operations become **WireMVC routes**, contributed by a single generated aggregate
> per spec.
>
> Taken to its conclusion, that means **one collation surface, not two**: `@OpenAPIController`
> contributes to `WireMVCKeys.routeContributors`, and M3's `TransportKeys.handlers` retires as a
> collated key. See *One collation surface* — it supersedes the two-mounting-modes framing an earlier
> draft carried, and it is what M3's own *WireMVC seam* section asked for.
>
> Builds on [WireOpenAPIDesign.md](WireOpenAPIDesign.md) (M3's shipped adapter),
> [WireMVCDesign.md](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/WireMVCDesign.md) and [WireMVCMiddleware.md](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/WireMVCMiddleware.md) (the routing
> and middleware surface being unified onto), the M5.4 request-scope proxy
> (Archive/M5_4_PLAN.md), and
> [RouteErrorHandling.md](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/RouteErrorHandling.md). Depends on the pluggable decomposition designed in
> [DecompositionTransformers.md](https://github.com/tachyonics/wire-mvc/blob/main/Proposals/DecompositionTransformers.md), whose 1a/1b slice M6d owns.
>
> The spec remains the source of routing truth throughout; the generator remains the owner of
> request/response binding. What moves is *where operations are registered*.

## What M6d is

`@OpenAPIController` today is the thinnest adapter in the system: a `@Contributes` alias plus a
generated witness that calls `registerHandlers`. Everything above that line is hand-written, and an
app that also uses WireMVC has two of everything.

| | today | M6d |
|---|---|---|
| **handler shape** | hand-written `(Operations.X.Input) -> Output` | annotated handler; the conformance is generated |
| **scope** | app-scoped only | `@Scoped(seed: HTTPRequest.self)`, per controller |
| **middleware** | none | `@Middleware` at controller and route level — *the same components as WireMVC routes* |
| **errors / 404 / entry point** | app-owned | `@ErrorResponse` tiers, `@NotFound`, `@WireMVCBootstrap` |
| **routes per spec** | one controller, all operations | split across controllers by tag |

**Non-goal: spec emission.** Generating `openapi.yaml` *from* annotations is the opposite direction
and is not M6d.

**Non-goal: owning request/response binding.** Taking over decoding as well as routing is a third
position (see *Why not full takeover*); it trades compile-checked coupling for silent semantic
coupling and is explicitly rejected here.

## The seams this rides

Three, none built for this, none needing a shape change.

### 1. Plugin-owned codegen with a body hole

`Sources/WireGenCore/ContributorProxyEmission.swift` emits the **structural half** of a contributor
proxy — stored fields (`_wireSubject`, `_wireFactory_<key>`, or `_wireEnterScope` for a bridging
proxy), the init the graph's construction call targets, and `: Sendable` on the declaration — and
deliberately leaves a **body hole**: no conformance, no witness. A domain tool fills it in the same
module, meeting the struct on documented field names. WireMVC's `WireMVCRouteGen` is the only
consumer today; `WireMVCBuildPlugin` orchestrates WireGen then the domain tool over one source set.

M6d makes WireOpenAPI the second consumer of exactly that arrangement. WireGen is already exposed as
an executable product for precisely this reason.

### 2. The seed types coincide

WireMVC's request scope is seeded on `HTTPRequest` (swift-http-types). OpenAPIRuntime's currency at
its transport and middleware boundaries is the *same* `HTTPRequest`. So a request-scoped binding is
shareable across both kinds of route on one graph — one seed type, one scope model.

### 3. The bridge already exists, pointing the other way

`WireMVCServerTransport` mounts proposal-native WireMVC routes onto a `some ServerTransport`,
fabricating a reader from an `HTTPBody?` and a sender that feeds one back (streaming, with real
backpressure — spikes 13/14). M6d needs the *inbound* direction: a `ServerTransport` whose
registrations become WireMVC routes. Same fabrication, opposite direction, and easier — the
transport's currency (`HTTPBody`) is copyable.

## The transport interaction — and why one aggregate

Read off the generated `Server.swift` and OpenAPIRuntime's `UniversalServer` in spike-28.

**Registration.** `registerHandlers(on:serverURL:configuration:middlewares:)` — an extension method on
`APIProtocol` — builds a `UniversalServer(handler: self, …)` and issues one
`transport.register(closure, method:, path:)` per operation. The transport is a parameter, never
stored. `UniversalServer` copies the handler into `@Sendable` closures that live for the process,
which is why any conformer must be app-scoped and `Sendable`, and why per-request state can only
arrive through a scope-entry thunk.

**Per request.** `UniversalServer.handle` builds `next = { deserialize → handler → serialize }` and
wraps it with `for middleware in middlewares.reversed()`. Two facts follow: a `ServerMiddleware` sees
the request *before* decoding, in the same task as the handler; and **decode failures never reach the
adapter** — the runtime maps them, so WireMVC's `@JSONBody` content-type rules are not re-implemented
for OpenAPI operations. The generator owns binding, in both directions.

> **Half wrong, found by serving it (M6d.4).** The runtime *classifies* a decode failure — wrapping it
> in a `ServerError` carrying an `httpStatus` — and then **rethrows**. It does not produce a response. In
> a stock deployment the *transport* catches that and answers; here WireMVC is the transport and knew
> nothing of it, so the error escaped to the router, which had no response to write and dropped the
> connection: `curl` reporting no reply at all to a request with a malformed body. The terminal now
> catches `HTTPResponseConvertible`, which `ServerError` conforms to, so the mapping is still the
> runtime's own and not one invented here. What holds is the second half: binding is not re-implemented.

**The constraint — as it stood.** `registerHandlers` is generated **once per document** and registers
**every** operation from a single conformer. So two `@OpenAPIController` types in one target could not
split the API: each would have to implement the whole `APIProtocol` and each would register the full
route set. Since the generator plugin takes one `openapi.yaml` per target, that meant *one conformer
per spec*. M3's note reads as though it assumed otherwise ("each handler registers *its own*
operations"), so this was an unexamined assumption rather than a decision.

Left alone, that constraint would force: controller-scope ≈ global scope, request scope all-or-nothing
per API, and one enormous controller type per document. **The aggregate is the answer to all three.**

> **Superseded in part (M6d.3).** Registration is no longer how operations are mounted — see *Direct
> dispatch* below. Each operation is mounted individually and forwarded to the controller that declared
> it, so **several controllers may share one spec**, at independent scopes and with independent
> controller-scope middleware. What survives is *one conformer* per spec — the type implementing
> `APIProtocol` — but it now holds one subject per contributing controller rather than being one
> controller. The aggregate is still the answer; it is just no longer forced by registration.

## The model — one aggregate per spec, mounted as WireMVC routes

Because the conformer is *ours*, it does not have to be one user type. The plugin generates a single
aggregate per spec that wears two hats: it satisfies `APIProtocol` by dispatching each operation to
whichever controller declared it, and it satisfies **`RouteContributor`** by registering each
operation as a WireMVC route with that controller's middleware chain.

### What the user writes

```swift
// One middleware component, used by both kinds of route — the point of the exercise.
@Singleton struct RequireAPIKey: Middleware { … }        // the proposal's Middleware
@Singleton struct AuditLog: Middleware { … }

// ── WireMVC-native routes ──────────────────────────────────────────────
@Singleton
@Controller("/admin")
@Middleware(RequireAPIKey.self)               // controller level
struct AdminController {
    @Get("/health") @JSONResponse
    @Middleware(AuditLog.self)                // route level
    func health() async throws -> Status { … }
}

// ── OpenAPI operations — identical annotations, identical components ───
@Scoped(seed: HTTPRequest.self)
@OpenAPIController("/api/v1")
@Middleware(RequireAPIKey.self)
struct TaskController {
    @Operation("getTask") @JSONResponse
    @Middleware(AuditLog.self)                // route level, per operation
    func getTask(@Path id: UUID) async throws -> Components.Schemas.Task { … }

    @RawOperation
    func exportTasks(_ input: Operations.ExportTasks.Input) async throws -> Operations.ExportTasks.Output { … }
}

@Singleton                                    // an app-scoped peer on the SAME spec
@OpenAPIController("/api/v1")
@Middleware(RequireAdmin.self)
struct ReportController {
    @Operation("listReports") @JSONResponse
    func listReports() async throws -> [Components.Schemas.Report] { … }
}

@Singleton
@WireMVCBootstrap
@Middleware(RequestLogger.self)               // global front layer — covers everything
@NotFound
struct App {}
```

### What is generated

```swift
// WireGen — the structural half: fields, init, Sendable, body hole. One per SPEC.
struct _WireOpenAPI_TasksAPI: Sendable {
    let _wireEnterScope_TaskController: @Sendable (HTTPRequest) async throws
        -> (TaskController, @Sendable () async -> [any Error])
    let _wireSubject_ReportController: ReportController
    let _wireFactory_requireAPIKey: RequireAPIKey
    let _wireFactory_requireAdmin: RequireAdmin
    let _wireFactory_auditLog: AuditLog
}

// WireOpenAPIGen — hat 1: satisfy the protocol, dispatching per operation.
extension _WireOpenAPI_TasksAPI: APIProtocol {

    // Scope discipline emitted once per scoped subject rather than once per operation.
    private func _wireWithScope_TaskController<R>(
        _ body: (TaskController) async throws -> R
    ) async throws -> R {
        let (controller, teardown) = try await _wireEnterScope_TaskController(WireOpenAPIRequest.current)
        do { let r = try await body(controller); _ = await teardown(); return r }
        catch { _ = await teardown(); throw error }
    }

    func getTask(_ input: Operations.GetTask.Input) async throws -> Operations.GetTask.Output {
        try await _wireWithScope_TaskController { controller in
            let id = try OpenAPIPath<UUID>.bind(name: "id", from: input.path.id)
            return .ok(.init(body: .json(try await controller.getTask(id: id))))
        }
    }

    func exportTasks(_ input: Operations.ExportTasks.Input) async throws -> Operations.ExportTasks.Output {
        try await _wireWithScope_TaskController { try await $0.exportTasks(input) }   // @RawOperation
    }

    func listReports(_ input: Operations.ListReports.Input) async throws -> Operations.ListReports.Output {
        .ok(.init(body: .json(try await _wireSubject_ReportController.listReports())))  // app-scoped peer
    }
}

// WireOpenAPIGen — hat 2: one WireMVC route per operation, each with ITS controller's fold.
extension _WireOpenAPI_TasksAPI: RouteContributor {
    func registerWireRoutes<Builder: HTTPServerRouteBuilder>(on builder: inout Builder) throws
    where Builder.RequestContext: ~Copyable, Builder.Reader: ~Copyable,
          Builder.ResponseSender: ~Copyable, Builder.ResponseSender.Writer: ~Copyable {

        // (a) Run the generator's own registration into a collector rather than a live transport.
        let operations = try WireOpenAPIOperations(
            collecting: self, serverURL: WireOpenAPI.serverURL("/api/v1")
        )

        // (b) One register per operation. Method and path come from the spec; the middleware chain
        //     from the declaring controller's annotations. Statically emitted, not looped.
        builder.register(method: .get, path: "/api/v1/tasks/{id}") {
            request, requestContext, pathParameters, reader, sender in
            // The SAME fold WireMVC's route codegen already emits — controller-outer → route-inner.
            try await WireMVCMiddlewareFold(_wireFactory_requireAPIKey, _wireFactory_auditLog)
                .run(request, requestContext, reader, sender) { box in
                    try await WireOpenAPI.invoke(
                        operations[.get, "/api/v1/tasks/{id}"], box: box, pathParameters: pathParameters
                    )
                }
        }

        builder.register(method: .get, path: "/api/v1/reports") { … }   // RequireAdmin only
    }
}
```

### The two new runtime pieces

```swift
/// A `ServerTransport` that captures registrations instead of serving them.
final class WireOpenAPIOperations: ServerTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws
        -> (HTTPResponse, HTTPBody?)
    private var entries: [Key: Handler] = [:]

    init(collecting handler: some APIProtocol, serverURL: URL) throws {
        try handler.registerHandlers(on: self, serverURL: serverURL)
    }
    func register(_ handler: @escaping Handler, method: HTTPRequest.Method, path: String) throws {
        entries[Key(method, path)] = handler
    }
    subscript(method: HTTPRequest.Method, path: String) -> Handler { entries[Key(method, path)]! }
}

/// The terminal: proposal primitives in, the generator's closure in the middle, primitives out.
/// The inverse of `WireMVCServerTransport`'s bridge.
enum WireOpenAPI {
    static func invoke(
        _ operation: WireOpenAPIOperations.Handler,
        box: consuming some MiddlewareBox,
        pathParameters: [String: Substring]
    ) async throws {
        try await box.withPendingContents { request, _, reader, sender in
            let body = try await HTTPBody(collecting: reader)
            let metadata = ServerRequestMetadata(pathParameters: pathParameters)   // types match exactly
            let (response, responseBody) = try await operation(request, body, metadata)
            try await sender.sendAndFinish(response, responseBody)
        }
    }
}
```

Two details that make this cheaper than it looks: WireMVC's matched path parameters are already
`[String: Substring]`, exactly what `ServerRequestMetadata` carries, so that hand-off is a
pass-through; and OpenAPI's `{id}` path templates are already WireMVC's `{name}` spelling, chosen in
M5 to match `ServerTransport`/OpenAPI path strings.

### What the aggregate buys

- **One routing model.** Both kinds of route land in one router, under one `@NotFound`, one global
  middleware front layer, one `@WireMVCBootstrap` entry point, one `@ErrorResponse` tier stack.
- **Per-operation middleware, using the same components** — because the fold is applied at *our*
  registration, before the generator's closure runs, where the box is real.
- **Per-controller scope.** `getTask` enters a request scope; `listReports` does not.
- **Specs split by tag**, with no user-visible seam.
- **Cross-controller diagnostics** — coverage becomes a property the plugin can check globally, the
  same argument M5 makes for route-conflict detection: an operation in the spec with no handler; two
  controllers declaring the same operation; an `@Operation` naming an operationId that isn't there.

### What the aggregate costs

- **A Wire capability — priced: ~250–350 lines across 7–8 files, zero in wire-mvc.** `.contributesProxy`
  synthesizes one proxy **per subject**; this needs one per *group of subjects*. The generalization is
  domain-free ("collate every subject bearing annotation X into one proxy of type T"). The conceptual
  change is small: `subjectIsNarrower` in `contributorProxyBinding` is currently a property of the
  *proxy* and becomes a property of each *subject*, so one aggregate can hold one controller directly
  while bridging into another's request scope. The mechanical ripple is the "at most one scope-entry
  thunk per proxy" assumption, encoded as `.first(where:)` in six places (`ScopeEntryEmission` ×3,
  `ScopeEntryLinking`, `SeedlessReconstructionEmission`, `ContributorProxyFacadeEmission`) — small
  individually, easy to miss collectively. Comparable in scale to M5.4.6 or 3.1c; a sub-iteration, not
  a milestone.
- **Keep the field names singular at N = 1.** `_wireSubject` is positional/unlabelled so the graph
  names no member — a trick that cannot survive N subjects. Suffixing only when N > 1
  (`_wireSubject_ReportController`) keeps today's emission byte-identical, leaves wire-mvc's 23
  references untouched, and keeps the 850 lines of existing proxy integration tests and the golden
  emission tests valid. New tests are then purely additive.
- ~~Generic controllers — bound it~~ — **no restriction needed** (`spike-29`,
  finding 1). The design feared a generic-parameter union with collision renaming and proposed limiting
  v1 to one generic subject. The existing transitive-lift machinery already carries two independent
  ones: a binding depending on `SearchController<Backend>` and `AuditController<Sink>` emits
  `_WireGraph<T0: AuditSink, T1: SearchBackend>` and binds the aggregate as `<T1, T0>` — axes mapped
  positionally and correctly *despite the graph ordering them differently*. What remains is not a lift
  problem: if synthesis copies subjects' parameter *names* verbatim, two subjects both declaring `T`
  collide in the emitted `<T, T>`. That is the same positional `T0`/`T1` renaming the graph already
  performs. **Allow N generic subjects; rename parameters positionally during synthesis.**
- **Grouping — two questions, two answers.** *Which operations does a controller handle?* **Spec tags**:
  `@OpenAPIController(tag: "tasks")` claims the operations carrying that tag, which gives the plugin a
  precise per-controller coverage set — *"you claimed `tasks`; the spec tags X and Y with it; Y has no
  handler."* Spec-driven, like the rest of the design. It layers over per-method identity rather than
  replacing it: an operation with several tags is ambiguous ownership (diagnostic), and an untagged one
  must be claimed by an explicit `@Operation`. *Which controllers share an `APIProtocol`?* Tags cannot
  answer that — two unrelated specs may both use a tag named `tasks`, and the plugin is syntactic so it
  cannot resolve the conformance target. Default to "all `@OpenAPIController`s in the graph" (nearly
  always one spec) and require an explicit discriminator only when two groups would emit conformances
  into the same module — diagnosed, never guessed.

## The annotation surface — one marker, per-method modes (decided)

`@OpenAPIController` stays the single type-level annotation; the handler spelling is selected **per
method** by `@Operation` or `@RawOperation`.

M3's precedent appears to argue for a second name — *"the two distinct annotation names keep the two
routing models legible instead of hiding them behind one mode-detecting macro"* — but what justified
two names there was two **sources of routing truth**. M6d changes nothing about routing: the spec
still owns paths, methods and statuses. Only the handler spelling differs.

Granularity settles it. `@RawOperation` — the escape hatch for multipart, streamed bodies, and
anything the annotation set can't express — is inherently per method, so a type-level annotation
cannot express the mode. Two names would also forbid mixed controllers, and so forbid incremental
migration. M5's visible-and-greppable-mode principle is satisfied at method granularity: grep
`@Operation`.

**`@RawOperation` is required** on every hand-written method of a Wire-managed controller. Recognising
them by signature shape would put a heuristic in the plugin, and every heuristic here has eventually
been replaced by an explicit spelling (`@RawRoute` roles; `@MiddlewareFactory` positional roles).

## Mixed controllers

The aggregate implements every `APIProtocol` requirement, choosing per method between a generated
shim and a one-line forwarder (both shown above).

**The controller drops `: APIProtocol`, and the compiler forces it.** Converting one method makes its
signature stop satisfying the requirement (`getTask(id:) -> Task` is not `getTask(_ input:) ->
Output`), so a controller still declaring the conformance fails to build. Once it is gone the
aggregate is the sole conformer and completeness is compiler-checked — with spec parsing, a
diagnostic instead.

**Migration path**, each step independently reviewable:

1. **Today.** The controller conforms; the proxy delegates `registerHandlers`. Untouched M3.
2. **Adopt.** Drop `: APIProtocol`; mark every method `@RawOperation`. Behaviour identical, no bodies
   rewritten — mechanical enough to ship as a fix-it.
3. **Convert** one operation at a time to `@Operation` + parameter/response annotations.
4. Optionally end with no `@RawOperation` left — or keep some permanently.

**Sharp edges.**

- **Identity for raw methods.** Bare `@RawOperation` relies on the method name matching the generated
  requirement — true unless renamed; `@RawOperation("createTask")` covers that case.
- **Visibility.** The forwarder calls the subject from the consumer module, so a controller in a
  library needs `public` methods — the same reason its packaging needs `accessModifier: public`.
- **The one conditional shape.** A controller with no markers keeps its own conformance so today's M3
  controllers compile untouched. That runs against the preference that made the contributor proxy
  unconditional in 3.1c, so it is labelled compatibility, not a mode: pre-1.0 it can be deleted by
  requiring markers, at the cost of a one-time (fix-it-able) migration.

## Direct dispatch (M6d.3) — and the generator change it needs

Mounting an operation individually, rather than replaying `registerHandlers`, is what unlocked
multi-controller and multi-spec. It rests on one fact about the generated `Server.swift`: the
per-operation methods on `UniversalServer` — `server.getTask(request:body:metadata:)` — hold the **only
copy of an operation's deserializer/serializer pair**. `handle` is public but takes them as arguments,
and those closures are written inline in those methods and exist nowhere else. So dispatching one
operation means calling one, and the alternatives are the two already rejected: go through
`registerHandlers` (which fixes the handler by value), or re-derive the coding layer from the spec,
which is the full takeover this note rejects.

Stock swift-openapi-generator makes that impossible. Two changes, both small and both upstreamable,
carried on a fork meanwhile:

1. the `UniversalServer` extension is emitted `internal` rather than `fileprivate`, so other generated
   code **in the same module** can call it;
2. its methods follow the configured `accessModifier:` rather than being internal regardless — as
   `registerHandlers` in the same file already does — which is what a spec generated into its own
   module needs, since its caller is in another module.

Because those methods extend `UniversalServer`, which is `@_spi(Generated)`, they remain SPI however
public they are declared: the emitted file imports a spec module `@_spi(Generated)` too.

**Cost per request:** a four-field struct copy and a conformer construction. The `Converter`, and the
coders it allocates, are built once for the process.

### Two specs in one app

The generator names its types from nothing about the document, so **every** spec module spells them
`APIProtocol`, `Operations`, `Servers`, `Components`. In a module importing two, a bare
`Operations.GetOrder.Input` is *"ambiguous for type lookup"* — and that includes the spellings copied
verbatim out of a controller that was unambiguous where it was written. This is spike-28's
same-spelling hazard arriving for real.

Each spec's conformer is therefore emitted inside a namespace whose typealiases resolve it:

```swift
enum _WireOpenAPISpec_OrdersAPI {
    typealias Operations = OrdersAPI.Operations
    …
    struct Conformer: APIProtocol { … }   // forwarders keep the author's spellings, qualified or not
}
```

Verified by prototype before building: the namespace resolves a controller that qualified and one that
did not; removing a single typealias reproduces the exact ambiguity; and a module's **own**
declarations win over identically-spelled imported ones, so an app may generate one document itself and
import another.

`spec:` has one meaning per form and no fallback. Bare `@OpenAPIController()` is this target's own
document; `@OpenAPIController(spec: "M")` says the generated `APIProtocol` is module `M`'s; a value
naming no such dependency is an **error**, not a label quietly resolved against the local document. It
cannot be derived from where a controller is declared — controllers routinely live apart from the
document they implement, which is the whole reason the argument exists.

Two constraints fall out for a module holding a generated document: it must generate `public`, and it
must **not** enable `InternalImportsByDefault` (the generator emits plain `import` lines, and a public
method whose parameters come from an internally-imported module does not compile).

## The typed shim

Parameter binding is a **decomposition keyed by input type**.
[DecompositionTransformers.md](https://github.com/tachyonics/wire-mvc/blob/main/Proposals/DecompositionTransformers.md) already argues the general form:
transformers dispatch on *the input type the handler actually receives*. `Operations.X.Input` is a
third input shape alongside the middleware box and the raw primitives. WireMVC's shipped
`RequestBound.bind(name:request:pathParameters:body:)` is request-shaped and does **not** carry over —
the values are already decoded and live at `input.path.id` / `input.query.page` / `input.body`.

**M6d owns the transformer registry.** The 1a/1b slice is deferred "until `@Configuration` forces it,
or on a deliberate decision to buy the typed-handler surface" — only the second branch applies. M6c's
`@Configuration` is a different annotation at different sites: three **graph-construction** sites
desugaring to a synthesised `ConfigReader` binding, "no new adapter form, no contract extension". So
M6c does not shrink this work.

> **Built without it, and the registry stays deferred (M6d.4).** Binding is emitted directly against a
> fixed set of four wrappers rather than through a registry. Nothing is extensible as a result — an app
> cannot add a binding of its own — but wire-mvc does not offer that either, and its route codegen binds
> by the same fixed set. A registry that only one of the two adapters had would be the wrong shape: this
> belongs in wire-mvc as a base mechanism both lean on, and until it exists there, adding one here would
> mean two parallel dispatch models rather than one.

### What was built (M6d.4)

The surface the note sketched, with one correction and one addition.

**The correction: the binding annotations are property wrappers, not macros.** `@Path id: UUID` cannot
be a macro at all — Swift rejects it with *"'peer' macro cannot be attached to parameter"*. WireMVC's
`@Path`/`@Query`/`@Header`/`@JSONBody` are `@propertyWrapper` structs, which SE-0293 does allow on a
parameter, so they are usable **as they are**: the adapter reads the *same types*, not a parallel set.
That is the unification claim discharged rather than asserted. `@Operation` is new and is an ordinary
peer marker.

**The addition: the document decides more than the note assumed.** A parameter's *location* is read
from the document, never from the annotation — the annotation says only which parameter is meant. So
`@Query` on something the spec puts in the path is an error rather than a silent misbinding, and a
`$ref`'d parameter resolves like any other. The same rule extends to responses and request bodies: which
status a handler constructs, whether it carries a body, and whether that body is optional are all read
from the document, and the handler is checked against it.

    @Operation
    func summariseTask(
        @Path id: String,
        @Query("include-done") includeDone: Bool?,
        @Header("X-Request-Id") requestID: String?
    ) async throws -> Components.Schemas.Task

`@JSONResponse(status:)` and `@ResponseStatus(_:)` name the response where the document declares more
than one success — split on whether the handler returns a body, the same split WireMVC draws.

### Type-driven now, spec-driven validation next

Type-driven emission derives `input.path.id` and `.ok(.init(body: .json(…)))` from the annotations and
a status→case table, letting the Swift type checker validate against the generator's output.
Spec-driven adds real build-time diagnostics: unknown `operationId`, a parameter annotated `@Path`
that the spec puts in query, an undocumented status, an uncovered operation, cross-controller
duplicates.

### Naming: two transcriptions, held by the generator itself

Naming generated symbols is what the typed shim added that no earlier milestone needed. Every prior one
copied spellings the author had already written; the shim has to *produce* `Operations.GetTask` from an
operationId, `input.path.userId` from a parameter name, and `.created` from a status.

Measurement killed the cheap options first. The namespace is **not** the capitalised method name —
`httpProxyURL` becomes `HTTPProxyURL` — and the relationship differs by strategy: under `defensive` the
namespace *equals* the method name, under `idiomatic` it does not. And the transform is `internal` to
`_OpenAPIGeneratorCore`; `NamingStrategy` is public but is a two-case enum carrying none of the
behaviour, so there is nothing to call. A validate-and-reject predicate covering only the identity cases
was priced and rejected for one reason: header names are conventionally hyphenated, `X-Request-Id`
becomes `xRequestId` under either strategy, so `@Header` would have been unusable.

So `SafeNameGenerator` and `HTTPStatusCodes.safeName(for:)` are transcribed into `WireOpenAPINaming`,
kept structurally identical to upstream and excluded from this package's formatter and linter — the
file's value is that a future diff against upstream stays readable, and bringing it in line with local
style is the one change that would destroy that.

**What makes a copy safe is not the copy.** It fails when the original moves and ours does not, surfacing
as "cannot find type" inside generated code. So the golden tables are produced by *running the
generator*: `swift run NamingGoldenTool` builds a corpus document, generates under both strategies, and
reads back the names it emitted — exhaustively for statuses, 100 through 599. Unit tests hold the
transcription to those tables; CI runs the tool with `--check`, so a generator bump that changes naming
fails with a name-by-name diff rather than silently.

Two facts worth carrying into any future work here. `Config.defaultNamingStrategy` is **defensive**, so a
document that merely omits the setting is not the arrangement most examples show. And status 100 is
emitted as a backticked `` `continue` `` — the backticks are part of the name.

The enabler: `openapi.yaml` and `openapi-generator-config.yaml` are **source inputs of the target**,
not another plugin's outputs, so reading them has no plugin-ordering hazard. Reading the generator's
emitted `Types.swift` would, and is forbidden.

Emission is identical either way, so validation is additive. One exception: read
`openapi-generator-config.yaml`'s `namingStrategy` from day one, since it changes the spelling of
every generated member the shim touches.

> **Done, and the document is read with OpenAPIKit (M6d.5).** The diagnostics listed above all exist. The
> reading behind them does not use Yams directly any more: a dictionary walk worked for documents shaped
> like the fixture's and quietly mishandled the rest — a parameter declared by `$ref` carries no `name`,
> so it was dropped, and a handler binding it was then rejected for binding something *"the document does
> not declare"*, a false error against ordinary OpenAPI. It now decodes with OpenAPIKit, the model the
> generator itself uses, including its version handling, and calls `locallyDereferenced()` once so nothing
> downstream can forget to follow a reference. Range and `default` response keys are excluded
> deliberately: they name no single status, so a typed handler cannot construct one.
>
> `namingStrategy` is read, as instructed — both plugins pass the config file and declare it an input, so
> changing the strategy re-runs this tool and not only the generator.

## Request scope

The aggregate is app-scoped and holds a scope-entry thunk per `@Scoped(seed:)` controller. Everything
downstream is reused verbatim from M5.4: the `(Seed) async throws -> (Subject, @Sendable () async ->
[any Error])` contract, per-root reachability (M5.4.6), request-scope teardown (M5.4.5). A
`@RawOperation` gets a freshly constructed per-request subject exactly like a typed one.

**Scope entry lives in the route terminal — decided, for consistency with WireMVC.** M5.4.3 emits
`try await self._wireEnterScope(request)` at the terminal top; unified mode does the same, so the
scope's lifetime, its teardown point and its failure handling are identical for both kinds of route.

- **`@ErrorResponse` keeps control of scope-entry failures.** M5.4E explicitly covers "a request-scoped
  binding that throws while the terminal constructs the request scope" — mapped by the terminal's
  `catch`. Entering scope inside the `APIProtocol` method instead would put that throw inside the
  generator's machinery, where *its* error handling maps it. This is the load-bearing reason, not
  aesthetics.
- **Teardown runs after the response is written**, so the scope outlives the middleware chain and a
  middleware that logs after `next` still sees it live.
- **The subject reaches the conformer by construction, not through ambient state.** This was designed
  as a task-local — believed structurally forced, because `registerHandlers` captures the
  `UniversalServer` and its handler by value at registration and offers no per-request channel. That
  premise held only while registration was how operations were mounted. Under direct dispatch the
  terminal copies a `UniversalServer` built once and points its `handler` at a conformer holding *this*
  request's subject, so there is no task-local and no ambient state at all.

  Three implementations were built and measured rather than argued about (release, single keep-alive
  HTTP/1.1 connection, 20k samples): app-scoped baseline 64.9µs p50; task-local 64.7µs; per-request
  re-registration 138.7µs; direct dispatch 69.8µs as the median of nine paired runs — level with the
  task-local at p50 and lower in mean and p99 in all nine. Two results worth keeping: per-request
  re-registration is **not** O(document size) as predicted (2→40 operations moved it 138.7→141.3µs) —
  its cost is `UniversalServer.init` building a `Converter`, which allocates two `JSONEncoder`s and a
  `JSONDecoder` once per request; and the first direct implementation made the same mistake, building a
  server per request and measuring *worse* than re-registration. Hoisting it to a template the request
  path copies and re-handlers is what made the strategy work. The rejected implementations are kept on
  `wire-open-api`'s `m6d-request-scope-strategies` branch.

**A request enters only the scope of the controller owning the operation it dispatches.** Entering
every scoped controller's scope would construct subjects the request never uses — the waste per-root
reachability (M5.4.6) exists to avoid. The conformer's other request-scoped fields are therefore
legitimately `nil` and never read; reaching one is a `preconditionFailure`, since it means generated
code was bypassed rather than anything a caller can cause.

**In-process testing needs no fallback.** The earlier design had the conformance enter its own scope
when no ambient one existed, a conditional shape forced by the task-local. With the subject supplied by
construction there is nothing ambient to be missing: a test calls the controller directly.

Note the capability argument for terminal entry is weaker than it looks: WireMVC's own middleware is
app-scoped (the `.injectsFromGraph` lift places it on the app-scoped proxy), so it cannot consume
request-scoped bindings either. Terminal entry does not unlock that today; it is the enabler if it is
ever wanted.

## Middleware, errors, configuration

**`@Middleware` — the proposal's `Middleware`, in unified mode.** Because the fold is applied at our
registration, before the generator's closure runs, the box is real: request, context, reader and
sender are all genuine, and the same components serve both kinds of route. Composition is WireMVC's:
source-order, controller-outer → route-inner → terminal.

WireMVC's *type-transforming* property still does not apply — `Operations.X.Input` is fixed by the
spec, so the terminal's input is not negotiable. That is not a regression but the decision M5.4
already took: middleware-produced values reach handlers by **A-inject** (request-scope injection),
not by parameter projection off the box.

**Mounting on a foreign `some ServerTransport`** goes through `WireMVCServerTransport.apply`, which
registers the collated routes and bridges them — so the operations arrive as routes and their middleware
folds with them. Had a WireOpenAPI-specific facade survived the fold (it did not; see below), it would
have had no route to fold middleware around at all: the only interception point on that path is the
transport boundary. Middleware consistency is reachable through a route and unreachable through a bare
transport registration, which is the sharpest argument for one collation surface.

**`@ErrorResponse`.** The M5.4E model is terminal-scoped — pairs and closures folded into the generated
`catch`, route-inner → controller-outer, first-match-wins, no graph injection. It transfers with one
adaptation: the terminal returns an `Output`, so a mapping produces a **documented response case**
where one exists and `.undocumented(statusCode:)` otherwise. Knowing which statuses are documented is
the spec read, so this sequences after it.

> **Built (M6d.6), across two sites.** It transfers, with more adaptation than the paragraph above
> anticipated, because *where* a mapping is matched decides what it can do.
>
> **In the forwarder**, an error still has the author's own type and an `Output` is the value being
> returned, so a mapping produces the document's own response case and the generator serialises it exactly
> as it would a success. **At the terminal**, via a hook the witness supplies, for what the forwarder can
> never see: a body the deserializer rejected is thrown *before* the forwarder is entered. `DecodingError`
> and `Swift.Error` are matched at both, since a handler can throw them too — the forwarder copy only
> where the document declares the status, because taxing every covered operation would penalise exactly
> the mappings meant to be broad.
>
> An earlier draft of this note claimed the original error was unreachable outside the forwarder, behind
> the internal `RuntimeError`. That was wrong: `makeError` unwraps `handlerFailed` and
> `failedToParseRequest` into the public `ServerError.underlyingError`, so the author's error and a
> `DecodingError` are both reachable there. What is *not* reachable is the missing-value and
> unexpected-content-type family, which returns `nil` from that unwrapping and stays behind the internal
> type — matchable only by a catch-all, and otherwise keeping the runtime's 400/415, which are already the
> right answers. Exposing those publicly is a small, precise ask of swift-openapi-runtime.
>
> **Two forms, and the document picks which is legal**, which is what turned "a documented error body
> means `@RawOperation` for the whole operation" into something expressible:
>
> | the document says that status… | the only legal form |
> | --- | --- |
> | carries no body | `@ErrorResponse(E.self, .notFound)` |
> | carries a body | `@ErrorResponse(E.self, .notFound, { e in Problem(…) })` |
>
> The three-argument form is **wire-mvc's**, added there rather than here: it is meaningful for a `@Get`
> route too, and `UsersController` now uses it. That keeps the shared vocabulary shared. The closure form
> is not supported for operations and is not planned to be — it yields a status and bytes, and neither
> thing that buys (a status chosen from the error's value, a non-JSON body) can be resolved against the
> document or checked against it.
>
> A mapping in the forwarder must name a status the document declares, since it answers as one of the
> operation's responses. A terminal one need not: a request that failed to decode never became this
> operation's `Input`. `.internalServerError` is exempt at both — wire-mvc already ends its chain with an
> implicit 500, and a document promises 404 in a way it does not promise 500.
>
> Ordering is WireMVC's throughout: route-inner before controller-outer, first match wins, a shadowed
> mapping dropped rather than emitted as an unreachable `catch`, and a catch-all required to be last —
> wire-mvc's own rule, extended across scopes, since anything after one is dead code nothing else reports.
>
> One asymmetry to keep in view: the forwarder's copy is serialised by the generator and gets the
> document's declared headers; the terminal's is assembled here and sets only `Content-Type`. Inherent —
> the terminal never had an operation context — but the two copies are *near*-identical rather than
> identical.

**Coding — decided, and it did not land here (M6d.6).** M3's other explicit deferral was
`registerHandlers(configuration:)`. The question that replaced it is narrower and better: nothing calls
`registerHandlers`, so an app only has to supply the `Configuration` its `UniversalServer` is built with.

Asking *where* that setting belongs is what changed the answer. `dateTranscoder` and
`jsonEncodingOptions` are not OpenAPI concerns — a `@Get` route returning a `Date` has exactly the same
question, and was answering it differently. So the tier is **wire-mvc's**, not this adapter's:
`WireMVCCoding` (dates + JSON options) selected by `@Coding` at three scopes, innermost winning, the
same tiering `@Middleware` and `@ErrorResponse` use. This note's adapter contributes one bridge,
`Configuration(wireMVCCoding:)`, and the witness signature that carries the value inward.

**Why inward rather than around.** Global middleware wraps the finished router *once*, and that is valid
because middleware composes as a function of the request. Coding is consumed at leaf sites — inside each
route's binding and response encoding — so it cannot be wrapped around anything; it has to travel. Hence
`registerWireRoutes(on:coding:)` rather than a router-level decoration. This is the sharpest difference
between the two kinds of cross-cutting concern the adapter carries.

**The bug this fixed was live.** Foundation writes a `Date` as seconds since 2001 and the OpenAPI runtime
writes ISO8601, so one app served two spellings of the same instant depending on which authoring style
produced the route. The fixture now returns a fixed date from both kinds and CI asserts they agree —
though agreement alone is weak evidence, since ISO8601 is now the default on both sides. The fixture's
app-wide coding therefore asks for **sorted keys**, which is nobody's default: only an operation whose
`Configuration` was built from that value can produce it. A second controller overrides with a keyed
binding that writes epoch seconds, so the tiering is resolved by a running app rather than asserted in
generated text — and CI fails as loudly if the override leaks to the controller next door as if it never
applied.

**The mapping is total in both directions**, which is what makes routing OpenAPI coding through a
WireMVC tier safe rather than lossy. `JSONEncodingOptions` has exactly three members — `sortedKeys`,
`withoutEscapingSlashes`, `prettyPrinted` — and `JSONCoding` has a setting for each (wire-mvc gained
`prettyPrints` for the third). Nothing is dropped in transit. The **defaults deliberately differ** from
the runtime's `[.sortedKeys, .prettyPrinted]`: an app that says nothing now gets compact output from its
operations, because the app's settings win over one document's generated code.

**Selection is a `BindingKey`, after a wrong turn worth recording.** The first design gave `@Coding` a
`CodingSource` protocol, so each configuration needed a wrapper type declared solely to give the graph a
distinct type to key on. That was a second mechanism for a problem swift-wire already solves. The tell
was that the wrapper was never *optional*: swift-wire keys the graph by type and all three tiers select
the same type, so with types as the only selector there was one spelling for every scope, and an override
could never resolve to anything different. The protocol existed to manufacture the distinct types the
mechanism needed, not because "a coding source" is a real concept — which is the signature of a mechanism
invented around the absence of the right one.

`BindingKey<WireMVCCoding>` is the right one. `@Coding` now takes either a key or `WireMVCCoding.self`,
exactly as `@Middleware` takes either: the by-type form selects the unkeyed binding, which is what an app
with one coding wants — nothing to tell apart, so no name to invent — and a key earns its keep once a
second binding of the type exists. Naming *the same* binding at two nested scopes is then the residual
mistake, since it reads as an override and resolves to one value; it is diagnosed rather than ignored.
No swift-wire change was needed: `applyAdapterDependencies` already resolves `@X(K)` for any
`.injectsFromGraph` annotation.

### Response header fields — and the one place the mechanism differs

wire-mvc gained response header control after M6d: `@ResponseHeader` and a labelled response tuple for
routes, and a `ResponseHeaderRegistry` middleware contribute to. The registry rides the middleware box, and
a `WireMVCContext` courier carries it from the global front layer down to each route.

Operations inherit all of it, because they *are* WireMVC routes — a global `@Middleware` setting a security
header, a controller-scope one setting `Vary`, the tier order, the verbs. The emitter here took the same
four changes the wire-mvc codegen did: the witness's `Builder.RequestContext` gains
`ResponseHeaderCarrying`, the fold reads the registry off the courier and builds its box over the unwrapped
`takeBase()`, the no-fold path binds the courier, and the fold's factory specialisation moves to
`Builder.RequestContext.Base.self`.

**The one genuine difference is where the response head is built.** A `@Get` route's terminal constructs a
`WireMVCOutcome`, so contributions are resolved into it. An operation's response is built inside
`WireOpenAPIRoutes.invoke` from the generated `Output` type — there is no outcome to inject into. So its
terminal writes through `ResponseHeaderApplyingSender`, which resolves contributions into whatever head
passes through it. That is the same mechanism a `@RawRoute` uses, for the same reason, and it is what keeps
*one routing model* true of response headers: without it a global `@Middleware` would set a header on a
`@Get` route and silently not on an operation — the exact split M6d exists to close.

Declared, document-level response headers are a separate question and unchanged: the generator already
types those per response (`Output.Ok.Headers`), and they arrive as part of the `Output` value. What this
adds is the *ambient* tier — fields no single operation declares, contributed by middleware — which the
document has no way to express.

CI asserts the header on both an operation and an annotation-driven route. Asserting one kind only would
let the other regress unnoticed, which is how the gap survived until the wire-mvc side had already merged.

**`@OpenAPIConfiguration` is deferred, and is now nearly empty.** What remains after coding moved out is
`multipartBoundaryGenerator` and `xmlCoder` — genuinely OpenAPI-only, with no WireMVC counterpart to
unify with. Neither has anything to act on: multipart and XML bodies are not supported at the terminal,
so the attribute would store values nothing reads. It waits for non-JSON bodies rather than shipping
ahead of them.

## One collation surface — `RouteContributor` (decided; supersedes two modes)

An earlier draft of this note carried **two mounting modes**: unified (operations become WireMVC
routes) and direct (the aggregate mounts on a foreign `some ServerTransport`), each with its own
collation key. That is retracted. **`@OpenAPIController` contributes to `WireMVCKeys.routeContributors`,
and `TransportKeys.handlers` retires as a collated key.**

**The two surfaces are inter-convertible, and both bridges now exist**: `WireMVCServerTransport` carries
routes *out* onto a `some ServerTransport`, and the collecting transport above carries `ServerTransport`
registrations *in* as routes. Once each is expressible as the other, two collation keys are duplication
rather than a separation of concerns.

**`RouteContributor` is the richer base**, so it is the one to keep:

- It carries the proposal's streaming primitives, the matched path parameters, and per-route middleware
  folding. `ServerTransport`'s currency (`HTTPBody`, copyable, buffered) is the narrower one.
- Everything an app actually wants attaches to **routes**: `@NotFound`, the `@ErrorResponse` tiers, the
  global middleware front layer, `@WireMVCBootstrap`. A transport registration can never participate in
  those; a route always can.
- Converting a transport registration into a route loses nothing — the collector replay is exact.

**It is also what M3 intended.** [WireOpenAPIDesign.md](WireOpenAPIDesign.md)'s *The WireMVC seam* says
the durable primitive is one collation surface, that `@OpenAPIController` and `@Controller` should land
in **the same key**, and that M5's controllers would be "a re-home, not a parallel surface". M5 then
declared `WireMVCKeys.routeContributors` instead, because its witness targets the route builder — so the
parallel surface M3 wrote to avoid is exactly what shipped. M3 picked the wrong base only because, when
it shipped, `ServerTransport` was the sole cross-runtime option; the proposal server was not yet
usable. Folding onto `RouteContributor` completes the re-home in the direction the evidence now supports.

**What it fixes.** The aggregate proxy was collated into `TransportKeys.handlers` only, so a
`@WireMVCBootstrap` app — which serves what reaches `WireMVCKeys.routeContributors` — never saw it.
Contributing to the route key dissolves that: no multi-key capability in swift-wire, no bootstrap
registration hook, no second `apply` in the composition root. The operations are routes, so the
bootstrap serves them because it serves routes.

**What it costs.**

- **wire-open-api depends on wire-mvc unconditionally.** `WireOpenAPIMVC` stops being an opt-in module
  and becomes the core. M3's headline property restates: not "depends only on `OpenAPIRuntime`" but
  "serves natively on any proposal server, and on Hummingbird/Vapor/Lambda through
  `WireMVCServerTransport`". Most of this was already paid when the package moved to tools 6.4/macOS 26.
- **A double hop for transport-only apps.** An app with no annotation-driven routes, serving on
  Hummingbird, goes collector → routes → `ServerTransport`: two conversions where M3 did none. Accept
  it. **`WireOpenAPI.apply` retires with the key** — do not keep it as a "direct-mount convenience",
  which is what an earlier draft of this section recommended.

  The reason is worth recording, because the idea is tempting and wrong. Such a facade takes the graph,
  and after the fold the graph's collection is *all* routes, not just OpenAPI ones — so it must filter
  by conformance, silently skipping every `@Controller` route in the app. An app calling it instead of
  `WireMVCServerTransport.apply` loses its annotation-driven routes with no diagnostic; an app calling
  both registers every operation twice. And nothing wanted it: `WireMVCServerTransport.apply` takes the
  same arguments and already does the job properly.

  The general rule this is an instance of: **once two things share a collection, a second API that
  reads that collection can disagree with the first.** The double hop is a bounded cost with a bounded
  fix (a fast path inside the bridge, not a parallel public entry point); silent partial registration
  is neither.

`TransportContributor` itself stays: it is exactly the shape `registerHandlers` needs, and the collector
consumes it. It is demoted from a collated key to plumbing.

## Why not full takeover

A third position — generate `types` only, drop `server`, and emit routing *and* binding ourselves —
would unify decode semantics too and buy content-type routing between handlers. It is rejected:

- The safety property of this design is that the shim is **type-checked against the generator's own
  types**; every row of the coupling inventory fails at compile time. Owning binding means our reading
  of the spec must match the wire with nothing checking it — parameter styles, `explode`, content-type
  matrices, `Accept` negotiation. Failures become silent protocol bugs.
- Reusing OpenAPIRuntime's `Converter` would shrink the work but it is `@_spi(Generated)`, explicitly
  listed as *not* API in the generator's stability policy.
- The effort is a second implementation of the generator's server half — comparable to M5 itself.

It stays reachable: unified mode already builds the `(method, path) → descriptor` table a takeover
would need, and M5's design rule keeps the registration backend swappable off that table.

## Sequencing — as planned, and as it went

Written as a plan and kept as a record: each entry now says what shipped, so the ordering rationale
below can be judged against what actually happened rather than against what was expected.

- **M6d.0 — the spike (the gate).** ✅ **Run — passed.** See *Spike results*.
- **M6d.0b — the proxy cutover.** `WireOpenAPIGen` + an adapter-owned `WireOpenAPIBuildPlugin` (the
  `WireMVCBuildPlugin` two-tool shape), the macro demoted to a marker, and a witness that delegates
  `registerHandlers` to the subject. No user-facing change and **no generated-symbol coupling**. Gate:
  existing consumers serve identically.

  **Go straight to `.contributesAggregateProxy`** rather than `.contributesProxy` and migrating later.
  The one-conformer constraint makes the aggregate the correct end shape even for a single controller,
  and a one-member aggregate emits byte-identically to the per-subject form — so adopting it now costs
  nothing and multi-controller support arrives with no second cutover. (Borne out: when the constraint
  was lifted in M6d.3, swift-wire needed no change at all — the aggregate already named a lone subject
  positionally and labelled each of several, deciding hold-vs-bridge per subject.)
- **M6d.0c — the aggregate capability.** ✅ **De-risked** — `spike-29`
  proved the shape: one aggregate holding hold, bridge and generic subjects at once, with per-request
  identity, teardown and per-root pruning all intact, driven by a *real* plugin-emitted scope-entry
  thunk. Remaining work is the synthesis: one-per-group proxy building, the N-ary dependency list,
  per-subject hold-vs-bridge in `contributorProxyBinding`, the six single-thunk call sites, N > 1 field
  name suffixing, positional generic-parameter renaming, and the grouping discriminator. ~250–350 lines,
  no wire-mvc change. Gate: two `@OpenAPIController`s on one spec producing one conformer.
- **M6d.1 — the inbound `ServerTransport`.** ✅ The collecting transport (`WireOpenAPIOperations`) and
  the terminal that adapts proposal primitives to the generator's closure. Needed no per-operation
  codegen: `registerHandlers` is the only thing that knows a document's operations and hands them over
  one at a time, so the operation set is *discovered by running it* against a collector. The generated
  conformance is one call delegating to the `TransportContributor` witness.
- **M6d.1b — fold onto `RouteContributor`.** `@OpenAPIController` contributes to
  `WireMVCKeys.routeContributors`; `TransportKeys.handlers` and `TransportComposable` retire as collated
  surfaces; `WireOpenAPIMVC` merges into `WireOpenAPI`; the generator always emits both conformances
  (no mode flag). **Unification lands here**, and the `@WireMVCBootstrap` gap closes without a new
  capability. Breaking for M3 consumers — cheap now, expensive once anything depends on two surfaces.
  Gate: an OpenAPI operation and a `@Get` route served by one `@WireMVCBootstrap` app.
- **M6d.2 — `@Middleware`** at controller and route level over operations, proposal `Middleware`, same
  components as WireMVC routes. ✅ Gate met: one `RequireAPIKey` applied to both kinds of route, with
  route scope proven distinguishable from controller scope.
- **M6d.3 — request scope**, via the aggregate's scope-entry thunks. ✅ **Landed, and larger than
  planned.** Delivering it required replacing registration with per-operation dispatch (see *Direct
  dispatch*), which then made two deferrals fall out almost for free:
  - **several controllers per spec**, at independent scopes, each keeping its own controller-scope
    fold. The one-conformer constraint no longer forces one controller;
  - **several specs per app**, each generated into its own module, resolved by per-spec namespaces.

  It also introduced this design's first hard dependency on the generator: two access-level changes,
  carried on a fork until upstreamed.
- **M6d.4 — the typed shim.** ✅ `@Operation`, parameter binding through WireMVC's own property
  wrappers, request bodies, and responses selected from the document. The dialect coupling did become
  broad, and naming it required transcribing two pieces of the generator (see *Naming*). The
  decomposition-transformer registry is **deferred** — wire-mvc has no such mechanism either, and it
  belongs there first.
- **M6d.5 — spec-read validation.** ✅ OpenAPIKit, the full diagnostic set, and both the document and the
  generator config declared as build-command inputs. Reading the document as a dictionary was the thing
  this milestone actually had to fix: `$ref`s were silently dropped.
- **M6d.6 — `@ErrorResponse` / configuration.** `@ErrorResponse` ✅ — the *one error model* claim is
  made good, across two sites and two forms, with wire-mvc growing the second form so the vocabulary
  stays shared. Coding ✅, but **in wire-mvc**: `dateTranscoder` and `jsonEncodingOptions` turned out not
  to be OpenAPI concerns at all, so they became `WireMVCCoding` and `@Coding`, and this adapter kept only
  the bridge. That closed a live inconsistency — the two kinds of route wrote dates differently — and
  makes the *one routing model* claim true of encoding as well as of middleware and errors.
  `@OpenAPIConfiguration` is **deferred**: what is left of it (`multipartBoundaryGenerator`, `xmlCoder`)
  has nothing to act on until non-JSON bodies are supported at the terminal. See *Middleware, errors,
  configuration*.
- **Docs + the forcing case.** This note is now a decision record and `WireOpenAPIDesign.md` carries the
  forward pointer ✅. **task-cluster is not yet migrated** — it is still on M3's hand-written
  `registerHandlers`, and it is the only remaining claim in this note that no running code makes. The
  fork should be upstreamed, or at least pinned to a revision, before anything else depends on it.

**Ordering rationale — partly overtaken.** The plan was that everything through M6d.3 is structural,
with no dependency on the generator's emitted symbol spellings, so the coupling table could be deferred
to M6d.4. That held for M6d.1–2 and failed at M6d.3: direct dispatch calls
`server.<operation>(request:body:metadata:)`, an emitted symbol, and needed the generator to widen its
access. The dialect coupling therefore starts one milestone earlier than written, and rows 15–17 below
are its first entries. Unification (M6d.1–2) did land before the DX work, as intended.

## Coupling inventory

What the design implicitly depends on, and how each failure announces itself. Almost every coupling
is compiler-checked, because the emitted code lands *in the same module* as the code it names. Two can
pass silently: the build-graph one (row 14/18), and row 24 — a runtime that *gains* a JSON option breaks
nothing and compiles clean, it just quietly stops being something an app can ask for.

**To swift-openapi-generator's output:**

| # | Dependency | Fails how |
| --- | --- | --- |
| 1 | `Components` / `Operations` / `APIProtocol` namespaces exist | compile: cannot find type |
| 2 | operationId → Swift type name (`namingStrategy`) | compile: cannot find type |
| 3 | `Input`'s `.path` / `.query` / `.headers` / `.body` shape | compile: no member |
| 4 | spec parameter name → Swift member name (safe-name transform) | compile: no member |
| 5 | status code → `Output` case + `.undocumented` | compile: no member |
| 6 | content type → body case and `Ok.init(body:)` | compile: no member |
| 7 | `registerHandlers` on `extension APIProtocol` | compile — **pre-existing; M3 relies on it** |
| 8 | ~~`registerHandlers` issues one `transport.register` per operation, keyed by method+path~~ | **retired at M6d.3** — nothing replays registration; routes come from the document |
| 9 | `accessModifier` ≥ controller visibility; `generate:` includes `types` + `server` | compile |
| 15 | per-operation methods exist on `UniversalServer`, named as the `APIProtocol` requirement | compile: no member |
| 16 | those methods are reachable — **needs the fork** (internal, and following `accessModifier:`) | compile: inaccessible due to protection level |
| 17 | a spec module's generated names collide with every other spec module's | compile: "ambiguous for type lookup" — **structurally avoided by per-spec namespaces** |
| 19 | the safe-name transform, **transcribed** (`GeneratorSafeNames`) | a generator bump changes naming → **CI, name-by-name**, via a golden generated by running it |
| 20 | the status→case table, **transcribed** (`GeneratorStatusNames`) | same, exhaustively over 100–599 |
| 21 | `Config.defaultNamingStrategy` is `.defensive` | silent misnaming of every symbol in an unconfigured document — pinned by a test |
| 22 | `ServerError.underlyingError` holds the *unwrapped* cause | an `@ErrorResponse` mapping stops matching — **runtime, and only for terminal-scoped mappings** |
| 23 | wire-mvc's three-argument `@ErrorResponse` | compile |
| 24 | `JSONEncodingOptions` has exactly three members, each with a `JSONCoding` counterpart | a fourth member is **silently unmappable** — the bridge stops being total and an app cannot ask for it |
| 25 | `DateTranscoder`'s two requirements match `DateTranscoding`'s | compile: the bridge is a forwarding wrapper |

Rows 19–20 are a different *kind* of coupling from the rest: not an assumption about output but a copy of
internal logic. They are the design's first, taken deliberately (see *Naming*) and held by generating the
expected values from the real generator rather than by asserting our own.

Row 8 was the unified model's only *runtime* coupling and is gone: routes are read from the document
and mounted individually, so there is no collector to come up empty, and no second derivation of the
registered path — the runtime's own `apiPathComponentsWithServerPrefix` composes it.

Rows 15–16 are the design's first hard dependency on the generator, and the only one that is not
satisfiable with a released version. Row 16 is the reason the fork exists; row 17 is a hazard the
emission avoids by construction rather than diagnosing.

Two properties limit the blast radius. The shim **constructs** `Output` rather than switching over it,
so the generator's worst documented breakage — adding a response or content type introduces an enum
case — cannot break it. And it **calls** `Ok.init(body:)` rather than referencing it as a function
value, which is what the generator's stability article asks of adopters.

That article commits to the plugin name, config format and CLI arguments; explicitly non-API are the
number and names of generated files, the `@_spi(Generated)` runtime surface, generated business logic,
and diagnostics. So rows 1–6 are a dialect the adapter owns deliberately: one version-pinned table,
golden-tested. Spec parsing narrows rows 2 and 4 from guessing to computing from the same inputs.
Depending on `_OpenAPIGeneratorCore` instead would trade a convention coupling for an
underscored-module one, and its naming logic is `internal` — only `runGenerator`/`Config`/
`NamingStrategy` are reachable.

**To WireGen:**

| # | Dependency | Fails how |
| --- | --- | --- |
| 10 | `_wireSubject` / `_wireFactory_<key>` / `_wireEnterScope` field names | compile: no member (spike-23's negative test) |
| 11 | the proxy type name | declared once in the capability |
| 12 | the proxy struct declares `: Sendable` | compile, at a confusing site — **pin with a golden test** |
| 13 | the scope-entry thunk's type string and its inverse parser | stringly-typed, internal to Core |

**To WireMVC** (unified mode): `RouteContributor`, `HTTPServerRouteBuilder.register`, the middleware
fold shape, `WireMVCKeys.routeContributors`, and — since response headers — `ResponseHeaderCarrying`,
`WireMVCContext.takeContents()`, the registry the box's destructures yield, and
`ResponseHeaderApplyingSender`. All compile-checked, all in-repo.

The response-header couplings are worth calling out as the sharpest in this table, because they all
landed at once and three of the four are *shape* couplings rather than name couplings: the box gained a
required `responseHeaders:` argument, the register closure's context became a courier that must be
destructured, and the fold's factory specialisation moved to `Builder.RequestContext.Base`. Making the
registry linear later moved that argument again — it is now taken from the box's own destructure rather
than a local, which is what keeps a wrapped sender disconnected. Each announces
itself at compile time, but only after wire-mvc's `main` is re-resolved — this package tracks it by
branch, so a break appears on the next update rather than in the PR that caused it.

**To the build graph:**

| # | Dependency | Fails how |
| --- | --- | --- |
| 14 | the spec is a declared `inputFiles` entry of the domain command | **silently stale** (finding 6) |
| 18 | a dependency module's document is likewise a declared input | **silently stale** — same failure, one module further out |

## Risks and open questions

- ~~The aggregate capability is unpriced~~ — **priced and de-risked**: a sub-iteration, not a
  milestone, and `spike-29` removed its one
  unbounded tail (the generic union). The emission side is bounded to six known call sites; the
  synthesis side is new code with no unknowns left in it.
- ~~Where scope entry lives~~ — **settled: the route terminal**, matching M5.4.3 (see *Request scope*).
- ~~The grouping discriminator~~ — **settled: spec tags for operation ownership**, a default-plus-
  diagnostic for spec membership (see *What the aggregate costs*).
- **Same-spelling generated types across modules** (finding 5). ⚠️ **Arrived at M6d.3** — two specs in
  one app is exactly this, and it is resolved structurally by per-spec namespaces (see *Two specs in
  one app*) rather than by the diagnostic this entry anticipated. Wire keys bindings by written type
  text, so two modules generating `Components.Schemas.Task` from one spec produce two nominal types
  with one spelling. Two failure shapes: both as bindings → a *"multiple bindings"* ambiguity whose
  message misleads (the user sees one name and concludes they duplicated a provider); one as a binding
  and one merely referenced → the graph declares the property with the unqualified spelling, which
  resolves in the consumer's module context to *its* type, so the error lands inside generated code at
  a line nobody wrote. Module selectors fix both, at every declaration site. The diagnostic to add:
  bindings carry `originModule`, so the plugin can detect *two bindings whose type spelling matches but
  whose origin modules differ, neither qualified*, and error with both source locations and a
  `Module::` fix-it — beside the existing duplicate-binding check in WireGenCore. A general hazard that
  generated code makes likely, which is why M6d surfaces it.
- **The fork.** ⚠️ **Arrived, and unresolved.** Direct dispatch and cross-module specs need two
  access-level changes to swift-openapi-generator, carried on a fork; a third, smaller ask now exists
  against swift-openapi-runtime (surface the missing-value decode causes so they are matchable by type).
  Neither is upstreamed, and `Fixtures/Package.swift` tracks a *branch* rather than a pinned revision, so
  CI can move underneath the project. Both are cheap to fix and neither is blocking, which is exactly how
  such things persist.
- **Non-JSON bodies and responses** are diagnosed toward `@RawOperation` rather than supported —
  `plainText` and `binary` carry `HTTPBody`, not a schema type, so the shim has nothing to construct.
  Whether they earn a form is unanswered.
- **Generated-symbol coupling** — see *Coupling inventory*; mitigation is one version-pinned dialect
  table with golden tests.
- **The extra body fabrication** on the Hummingbird/Vapor path in unified mode
  (`ServerTransport → WireMVC router → ServerTransport`). Measure before optimising; streaming already
  has a proven zero-buffering path in the outbound direction.
- **Testing.** `@Replaces`, `@BindType` and the variant app graph are graph-level and carry over.
  In-process testing needs no harness at all: construct the graph, take the aggregate, call the
  conformance — which is exactly what spike-28's `main.swift` does.
- **Multipart and streamed operations** land on `@RawOperation`. Whether they earn annotations is
  post-1.0.
- ~~The forcing case~~ — **settled.** task-cluster's stated direction is to move onto WireMVC's
  router, so the unified spine is the target architecture rather than a bet. Two consequences: the
  serving on a foreign transport is `WireMVCServerTransport.apply` rather than anything of this
  adapter's; and the
  extra body fabrication on the `ServerTransport → WireMVC router → ServerTransport` path is
  transitional — it disappears once the app serves the router natively.

## Spike results (M6d.0)

Run on Swift 6.3.3 and the 6.4.x-2026-07-06 snapshot / macOS, swift-openapi-generator 1.x. The fixture
puts **three** build-tool plugins on one target — `OpenAPIGenerator`, `WireBuildPlugin`, and a
`ShimGen` stand-in for `WireOpenAPIGen` that emits an `APIProtocol` conformance naming the generator's
types — then adds a second target so both a library and the executable run the generator. It builds
and runs.

**1. Plugins co-exist with no ordering hazard.** All are `.buildCommand`s; none declares another's
outputs as inputs, so they run independently and meet only at compile. This holds *because* the design
reads `openapi.yaml` rather than the emitted `Types.swift`.

**2. Wire's scan is indifferent to types that don't exist yet.** A `@Provides` binding whose *type* is
generated by the other plugin wires cleanly — stored property, resolved dependency edge, correct
topological order. The scan is syntactic. No Core change needed.

**3. `APIProtocol: Sendable` blocks conforming the user's own controller from a generated file.**

```
error: conformance to 'Sendable' must occur in the same source file as struct 'TaskController';
       use '@unchecked Sendable' for retroactive conformance
```

Writing `struct TaskController: Sendable` by hand clears it, but requiring that of users is the class
of footgun 3.1c removed. **The proxy path is immune by construction** — `ContributorProxyEmission`
already emits `: Sendable` on the declaration, so the domain extension adds only `APIProtocol`. An
independent re-derivation of the unconditional-proxy decision. The M3 witness is unaffected:
`registerHandlers` is on `extension APIProtocol`, so the proxy inherits it.

**4. The domain generator must emit the owning module's import.** The shim failed with `cannot find
type 'Operations' in scope` until it emitted `import Controllers` — so `WireOpenAPIGen` needs to *know*
which module owns the generated types.

**5. Two targets generating the same spec collide on binding identity.**

```
error: type 'Components.Schemas.Task' has multiple bindings; the dependency graph is ambiguous
```

Module selectors (SE-0491) resolve it and round-trip through codegen into accessor names
(`appComponentsSchemasTask` vs `controllersComponentsSchemasTask`), but must be written at **every**
declaration site in both modules. Qualifying one side only is worse than neither: the graph builds and
the consumer silently binds the dependency-module value into a property typed as the local same-named
type, failing inside generated code. A **Core** diagnostic work item.

**6. The build graph has no edge between the plugins.** Measured by the emitted shim's mtime: with only
`.swift` inputs declared, a spec-only edit re-runs swift-openapi-generator and **not** the domain tool;
adding the YAMLs to `inputFiles` fixes it. Harmless while emission is annotation-driven, **silent** the
moment the tool reads the spec. The only failure in the whole design that can pass a green build.

**Packaging consequence.** OpenAPI controllers must live in a target that can see the generated types —
the one running the generator, or one importing a library that runs it with `accessModifier: public`
(verified). Exactly one target should generate from a given spec unless every affected binding is
module-qualified.

## References

- [WireOpenAPIDesign.md](WireOpenAPIDesign.md) — M3's shipped adapter; the deferrals this note picks up.
- [WireMVCDesign.md](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/WireMVCDesign.md), [WireMVCMiddleware.md](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/WireMVCMiddleware.md) — the routing and
  middleware surface being unified onto. `WireMVCDesign.md`'s *Added after M5.0* records `@Coding`,
  which this milestone caused but which belongs there.
- [DecompositionTransformers.md](https://github.com/tachyonics/wire-mvc/blob/main/Proposals/DecompositionTransformers.md) — decomposition keyed by input type; the
  A-inject decision.
- [RouteErrorHandling.md](https://github.com/tachyonics/wire-mvc/blob/main/Documentation/Notes/RouteErrorHandling.md) — the `@ErrorResponse` model.
- Archive/M5_4_PLAN.md — scope-entry thunk, teardown, per-root reachability.
- Archive/WireMVCCodegen.md — Phase A, the plugin-owned orchestration
  WireOpenAPI becomes the second consumer of.
- [AdapterModel.md](https://github.com/tachyonics/swift-wire/blob/main/Documentation/Notes/AdapterModel.md) — the capability contract.
- `Sources/WireGenCore/ContributorProxyEmission.swift` — the body hole and its field-name contract.
- `spike-28` — the M6d.0 gate.

---

<sub>Milestone shorthand used in this note (M1, M5.4, M7b…) is defined in ROADMAP.md; outstanding gaps are indexed in KnownGaps.md.</sub>
