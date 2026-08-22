import Foundation
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

/// Errors a handler throws, mapped to responses by `@ErrorResponse`. Ordinary types: nothing about them
/// knows they will be mapped, which is the point — the mapping lives at the route, not in the error.
struct NoSuchTask: Error {}
struct NotAuthorised: Error {}

/// The store's *protocol*, so a controller can depend on it generically.
///
/// That shape matters more than it looks: `some TaskStoring` cannot be a stored property, so a controller
/// wanting the abstraction takes it as a lifted generic parameter which swift-wire concretizes when it
/// builds the graph. It is how a real app injects a repository, and it makes the aggregate proxy — and
/// therefore the emitted conformer — generic in step. `TaskListController` below is the generic one.
protocol TaskStoring: Sendable {
    func title(for id: String) -> String
    var count: Int { get }
}

/// An app-scoped dependency both controllers share, so the fixture also shows one graph behind both.
@Singleton(as: TaskStoring.self)
struct TaskStore: TaskStoring {
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
        trace("scope: constructed for \(self.path)")
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
struct TaskController<Store: TaskStoring> {
    @Inject let store: Store
    @Inject let identity: RequestIdentity

    /// The **mapped** tier for a schema-validation rejection: the document declares a 422 carrying a
    /// `Problem`, so the failure is answered as one of this operation's own responses and the generator
    /// serialises it exactly as it would a success.
    ///
    /// On a `@RawOperation` deliberately. Validation reads the generated `Input`, which a raw operation
    /// receives too, so it is not a typed-shim concern — and an author who took the raw escape hatch for
    /// the *response* shape still gets their document's assertions enforced.
    ///
    /// The throw is hand-written here because no emitter exists yet (slice 1). What it proves is the
    /// path, not the walk: this is exactly what a generated validator will throw.
    @RawOperation
    @ErrorResponse(
        WireOpenAPIRequestValidationError.self,
        .unprocessableContent,
        { error in Components.Schemas.Problem(message: "invalid: \(error.failures.map(\.path).joined(separator: ", "))")
        }
    )
    func getTask(_ input: Operations.GetTask.Input) async throws -> Operations.GetTask.Output {
        if input.path.id == "invalid" {
            throw WireOpenAPIRequestValidationError(
                operationID: "getTask",
                failures: [
                    .init(path: "body.title", keyword: "minLength", expected: "3", actual: "ab", location: .body)
                ]
            )
        }
        return .ok(
            .init(
                body: .json(
                    .init(
                        id: input.path.id,
                        title: "\(store.title(for: input.path.id)) via \(identity.path)",
                        at: fixtureDate
                    )
                )
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
// Controller scope: covers every operation this controller owns *except* those that map the same error
// themselves. `summariseTask` does, so it is not covered — which is what makes it an ordering test.
@ErrorResponse(NoSuchTask.self, .internalServerError)
// Matched at the *terminal*, not in the forwarder: a body the generator could not parse fails before the
// handler is ever called, so no clause inside it could see this. `DecodingError` is the standard
// library's, which is why it needs no vocabulary of ours — and mapping it here answers 422 where the
// runtime's own default is 400.
@ErrorResponse(DecodingError.self, .unprocessableContent)
struct TaskListController<Store: TaskStoring> {
    @Inject let store: Store

    /// The **typed** form. No `Operations.SummariseTask.Input` in sight: the parameters are bound from
    /// the document's `path`, `query` and `header` entries, and the return value is wrapped in the
    /// operation's response. The wrappers are WireMVC's own — the same `@Path`/`@Query`/`@Header` a `@Get`
    /// route uses, which is the unification this milestone is for.
    ///
    /// The names show why the binding cannot be spelling-by-convention: `include-done` and `X-Request-Id`
    /// reach the generated `Input` as `includeDone` and `xRequestId` under the idiomatic strategy, and as
    /// `include_hyphen_done` and `X_hyphen_Request_hyphen_Id` under the defensive one.
    /// `@ErrorResponse` on an OpenAPI operation, mapping a thrown error to a response the **document
    /// declares** — so the generator serialises it exactly as it would a success. 404 carries no body
    /// here, which is what lets a status-only mapping construct it; a documented body would be rejected.
    ///
    /// The controller below maps `NoSuchTask` too, to a different status — this one wins, because route
    /// scope folds inside controller scope and the first match takes it. `NotAuthorised` has no route
    /// mapping, so the controller's applies, and it names a status the document does *not* declare, which
    /// becomes `.undocumented(statusCode:)` — the generated escape, still a real response rather than a
    /// dropped connection.
    @Operation
    // The document's 404 carries a `Problem`, so a status alone cannot construct it — this is the form
    // that can, and the pair form is rejected here. Where the document declares no body, the reverse
    // holds. The document picks; the author cannot pick wrong without being told.
    @ErrorResponse(NoSuchTask.self, .notFound, { _ in Components.Schemas.Problem(message: "no such task") })
    @ErrorResponse(NotAuthorised.self, .forbidden)
    func summariseTask(
        @Path id: String,
        @Query("include-done") includeDone: Bool?,
        @Header("X-Request-Id") requestID: String?
    ) async throws -> Components.Schemas.Task {
        if id == "missing" { throw NoSuchTask() }
        if id == "secret" { throw NotAuthorised() }
        return .init(
            id: id,
            title: "summary of \(store.title(for: id)) done=\(includeDone ?? false) req=\(requestID ?? "-")"
        )
    }

    /// A non-200 success, inferred. The document declares exactly one success for this operation — 201 —
    /// so which response the handler builds needs no saying, and the shim emits `.created(…)`.
    /// A **required** request body, decoded by the generator and handed over as the schema type. The
    /// handler never names `Operations.CreateTask.Input.Body`.
    @Operation
    func createTask(
        @Query("title") title: String,
        @JSONBody draft: Components.Schemas.Task
    ) async throws -> Components.Schemas.Task {
        // A handler can throw the same type the deserializer does. The mapping covers both: this one is
        // caught inside and answered with the document's 422 case, while a body the *runtime* could not
        // parse is caught at the terminal and answered with the same status.
        if title == "corrupt" {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "handmade"))
        }
        return .init(id: draft.id, title: title)
    }

    /// A **no-content** response. Nothing here is special-cased about 204: the handler returns nothing,
    /// so the response it constructs must be one that carries no body — and since this operation
    /// documents two of those (202 and 204), it says which.
    ///
    /// `@ResponseStatus` rather than `@JSONResponse(status:)`, the same split WireMVC draws: one is for a
    /// handler that returns a body, the other for one that does not. Using the wrong one is diagnosed.
    @Operation
    @ResponseStatus(.noContent)
    func deleteTask(@Path id: String) async throws {
        // The **unmapped** tier, and the location split with it. Nothing maps a validation error on this
        // controller, so the answer comes from `HTTPResponseConvertible`: the runtime wraps the throw in
        // a `ServerError`, which lifts its status and body from the underlying error. A *parameter*
        // failure answers 400 where `getTask`'s body failure answers 422 — the same split
        // `WireMVCBindingError` already draws, so a `@Get` route and an operation agree.
        if id == "invalid" {
            throw WireOpenAPIRequestValidationError(
                operationID: "deleteTask",
                failures: [
                    .init(path: "path.id", keyword: "pattern", expected: "^[a-z]+$", actual: id, location: .path)
                ]
            )
        }
        // Not mapped here, so the *controller's* mapping answers it — 500, where `summariseTask`'s own
        // mapping of the same error answers 404.
        if id == "missing" { throw NoSuchTask() }
        trace("deleted: \(id)")
    }

    /// **Two** documented successes, so the document cannot say which one this handler returns and the
    /// author has to. `@JSONResponse` is WireMVC's own, like the parameter wrappers.
    @Operation
    @JSONResponse(status: .created)
    func replaceTask(
        @Path id: String,
        @Query("title") title: String,
        @JSONBody draft: Components.Schemas.Task?
    ) async throws -> Components.Schemas.Task {
        // The other blame. A response that violates the document is the *service's* fault, so it is a
        // different type answering 500 with **no body** — the caller did nothing wrong and can do nothing
        // about it, so there is no honest 4xx and nothing of the service's internals to hand over.
        if title == "badresponse" {
            throw WireOpenAPIResponseValidationError(
                operationID: "replaceTask",
                failures: [
                    .init(path: "id", keyword: "minLength", expected: "1", actual: "", location: .body)
                ]
            )
        }
        // The document does not mark this body required, so the generated `Input.body` is optional and
        // the handler has to be too. A disagreement either way is diagnosed.
        return .init(id: id, title: "\(title) from \(draft?.id ?? "nothing")")
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
struct StatusController<Store: TaskStoring> {
    @Inject let store: Store

    @Get("/tasks")
    @JSONResponse
    func taskCount() -> TaskCount { TaskCount(count: store.count, at: fixtureDate) }
}

/// The controller tier, overriding the app's coding for its own routes — and the first time an override
/// is exercised by a running app rather than asserted in rendered source.
///
/// It serves the same `TaskCount` as `StatusController` above, so the two responses differ only by the
/// coding that reached them: `/status/tasks` writes ISO8601 from the app tier, `/epoch/tasks` writes
/// seconds. That the first is unaffected is half the point — an override that leaked would be just as
/// wrong as one that never applied.
@Singleton
@Controller("/epoch")
@Coding(WireMVCCoding.epoch)
struct EpochController<Store: TaskStoring> {
    @Inject let store: Store

    @Get("/tasks")
    @JSONResponse
    func taskCount() -> TaskCount { TaskCount(count: store.count, at: fixtureDate) }
}

struct TaskCount: Codable, Sendable {
    let count: Int
    /// The other half of the comparison: this is encoded by WireMVC's own JSON response path, while
    /// `Task.at` above goes through the OpenAPI runtime's serializer. Before `WireMVCCoding` these two
    /// disagreed — Foundation writes a number of seconds since 2001, the OpenAPI runtime writes ISO8601.
    let at: Date
}

/// A fixed instant, so the two responses can be compared literally.
let fixtureDate = Date(timeIntervalSince1970: 1_700_000_000)
