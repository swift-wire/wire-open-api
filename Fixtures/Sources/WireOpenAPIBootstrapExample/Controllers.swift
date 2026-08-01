import HTTPTypes
import Wire
import WireMVC
import WireOpenAPI

// The whole point of the fixture: two controllers, two authoring styles, **one router**.
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

/// `@OpenAPIController` marks it; the plugin collates it onto `_WireOpenAPIContributor_Tasks`, which
/// carries the `RouteContributor` conformance. No base path here — the prefix is the document's
/// `servers:` entry (`/api/v1`), which `registerHandlers` reads.
@Scoped(seed: HTTPRequest.self)
@OpenAPIController(spec: "Tasks")
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

    /// Route-scope middleware: `Audit` folds around this operation only, inside the controller's
    /// `RequireAPIKey`. `@RawOperation` is what ties the method to the document's `listTasks`.
    @RawOperation
    @Middleware(AuditKeys.factory)
    func listTasks(_ input: Operations.ListTasks.Input) async throws -> Operations.ListTasks.Output {
        .ok(.init(body: .json(["1", "2", "3"])))
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
