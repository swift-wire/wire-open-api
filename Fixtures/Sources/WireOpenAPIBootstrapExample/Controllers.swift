import HTTPTypes
import OrdersAPI
import Wire
import WireMVC
import WireOpenAPI

// The whole point of the fixture: two authoring styles, **one router** — and, within the spec-driven
// style, two controllers sharing one document at two different scopes.
//
// `TaskController` implements the generated `APIProtocol` — the spec is the source of truth for its
// routing, and swift-openapi-generator owns its decoding and encoding. `StatusController` is an
// ordinary WireMVC controller. Both collate into `WireMVCKeys.routeContributors`, so the generated
// `@main` serves them the same way, under the same `@NotFound` and the same global middleware.

/// An app-scoped dependency both controllers share, so the fixture also shows one graph behind both.
@Singleton
struct TaskStore: Sendable {
    @Inject init() {}

    func title(for id: String) -> String { "task-\(id)" }
    var count: Int { 3 }
}

/// A request-scoped binding, seeded from the request being served — the same seed type a WireMVC
/// `@Scoped(seed: HTTPRequest.self)` controller takes, so both kinds of route share one scope model.
/// Its per-request value is what proves the subject is rebuilt rather than shared.
@Scoped(seed: HTTPRequest.self)
struct RequestIdentity: Sendable {
    let path: String

    @Inject init(seed: HTTPRequest) {
        self.path = seed.path ?? "/"
        print("scope: constructed for \(self.path)")
    }
}

// MARK: - spec-driven

/// `@OpenAPIController` marks it. The **bare** form means this target's own document — the one generated
/// alongside these sources — so nothing needs naming; `spec:` is for a document whose generated types
/// belong to another module, as `OrdersAPI` does. The plugin collates it onto `_WireOpenAPIContributor`,
/// which carries the `RouteContributor` conformance. No base path here — the prefix is the document's
/// `servers:` entry (`/api/v1`), applied by `apiPathComponentsWithServerPrefix`.
///
/// It implements **part** of the document. `TaskListController` below implements the rest, and the two
/// collate onto one proxy: operations are mounted individually, so a spec is no longer one object's to
/// serve. `APIProtocol` conformance is what checks the halves add up.
@Scoped(seed: HTTPRequest.self)
@OpenAPIController()
@Middleware(RequireAPIKeyKeys.factory)
struct TaskController {
    @Inject let store: TaskStore
    @Inject let identity: RequestIdentity

    @RawOperation
    func getTask(_ input: Operations.GetTask.Input) async throws -> Operations.GetTask.Output {
        .ok(
            .init(
                body: .json(.init(id: input.path.id, title: "\(store.title(for: input.path.id)) via \(identity.path)"))
            )
        )
    }

}

/// The other half of the same document — and **app-scoped**, where `TaskController` is request-scoped.
/// Scoping is decided per controller, so a request reaching `getTask` builds a `RequestIdentity` while one
/// reaching `listTasks` enters no scope at all.
///
/// It also declares **no** controller-scope `@Middleware`, which is the check that a group's controllers
/// do not share a fold: `RequireAPIKey` must run for `getTask` and not for `listTasks`. Both still reach
/// the same app-scoped `TaskStore`, so one graph sits behind the whole spec.
@Singleton
@OpenAPIController()
struct TaskListController {
    @Inject let store: TaskStore

    /// The **typed** form. No `Operations.SummariseTask.Input` in sight: the parameters are bound from
    /// the document's `path`, `query` and `header` entries, and the return value is wrapped in the
    /// operation's response. The wrappers are WireMVC's own — the same `@Path`/`@Query`/`@Header` a `@Get`
    /// route uses, which is the unification this milestone is for.
    ///
    /// The names show why the binding cannot be spelling-by-convention: `include-done` and `X-Request-Id`
    /// reach the generated `Input` as `includeDone` and `xRequestId` under the idiomatic strategy, and as
    /// `include_hyphen_done` and `X_hyphen_Request_hyphen_Id` under the defensive one.
    @Operation
    func summariseTask(
        @Path id: String,
        @Query("include-done") includeDone: Bool?,
        @Header("X-Request-Id") requestID: String?
    ) async throws -> Components.Schemas.Task {
        .init(
            id: id,
            title: "summary of \(store.title(for: id)) done=\(includeDone ?? false) req=\(requestID ?? "-")"
        )
    }

    /// Route-scope middleware: `Audit` folds around this operation only. `@RawOperation` is what ties the
    /// method to the document's `listTasks`.
    @RawOperation
    @Middleware(AuditKeys.factory)
    func listTasks(_ input: Operations.ListTasks.Input) async throws -> Operations.ListTasks.Output {
        .ok(.init(body: .json((1...store.count).map(String.init))))
    }
}

/// A controller for the **OrdersAPI** document that lives *here*, in the app, rather than beside its
/// document — the arrangement `spec:` exists for, and the one that makes it un-derivable: where this type
/// is declared says nothing about which document it implements. `spec: "OrdersAPI"` is what says so.
///
/// It shares the Orders document with `OrderController` in that module, so one spec is served by two
/// controllers in two modules, at two scopes, from one proxy.
///
/// Its types are written qualified, and must be: the bare `Operations` here resolves to *this* target's
/// own generated types — a module's own declarations win over imported ones — which describe the Tasks
/// document and have no `ListOrders`.
@Singleton
@OpenAPIController(spec: "OrdersAPI")
struct OrderSummaryController {
    @Inject let store: OrderStore

    @RawOperation
    func listOrders(
        _ input: OrdersAPI.Operations.ListOrders.Input
    ) async throws -> OrdersAPI.Operations.ListOrders.Output {
        .ok(.init(body: .json([store.item(for: "7"), store.item(for: "9")])))
    }
}

// MARK: - annotation-driven

@Singleton
@Controller("/status")
@Middleware(RequireAPIKeyKeys.factory)
struct StatusController {
    @Inject let store: TaskStore

    @Get("/tasks")
    @JSONResponse
    func taskCount() -> TaskCount { TaskCount(count: store.count) }
}

struct TaskCount: Codable, Sendable {
    let count: Int
}
