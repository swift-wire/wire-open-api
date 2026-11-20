// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import HTTPTypes
import Synchronization
import Wire
import WireMVC
import WireOpenAPI

/// The ids registered so far. App-scoped, so a second registration of the same id finds the first.
@Singleton
final class TaskRegistry: Sendable {
    private let registered = Mutex<Set<String>>([])

    @Inject
    init() {}

    /// Whether `id` is new, recording it either way.
    func register(_ id: String) -> Bool {
        registered.withLock { $0.insert(id).inserted }
    }
}

/// **Choosing a response, and its headers, on typed operations.** Each handler says something about its
/// response alongside the body — and the compiler holds it to what the document declares, because the
/// status and the headers are both generated or checked types, never a free status or free fields.
@Singleton
@OpenAPIController()
struct RegistrationController {
    @Inject let registry: TaskRegistry

    /// Find-or-create. The store decides whether the id is new, so the status is only known after the
    /// handler has run: 201 with a `Location` for a new task, 200 with an `ETag` for one already held.
    ///
    /// The status is `Operations.RegisterTask.SuccessStatus`, declared below with exactly the document's
    /// two successes, each carrying its response's generated headers. A status or a header the document
    /// does not describe cannot be written. `refused` throws, and the catch-all answers it with the
    /// document's 400 — which is what a catch-all is for.
    @Operation
    @ErrorResponse(Swift.Error.self, .badRequest)
    func registerTask(
        @Query id: String
    ) async throws -> (status: Operations.RegisterTask.SuccessStatus, body: Components.Schemas.Task) {
        let task = Components.Schemas.Task(id: id, title: "registered \(id)")
        struct Refused: Error {}
        if id == "refused" { throw Refused() }
        return registry.register(id)
            ? (.created(.init(location: "/api/v1/tasks/\(id)")), task)
            : (.ok(.init(eTag: "\"\(id)\"")), task)
    }

    /// The bodiless form, returned bare because Swift has no one-element labelled tuple: 204 when done at
    /// once, 202 with an integer `Retry-After` when it is only queued.
    @Operation
    func touchTask(@Path id: String) async throws -> Operations.TouchTask.SuccessStatus {
        id == "later" ? .accepted(.init(retryAfter: 30)) : .noContent
    }

    /// One bodiless success with a required integer header: the generated headers, returned alone.
    @Operation
    func markSeen(@Path id: String) async throws -> Operations.MarkSeen.Output.NoContent.Headers {
        .init(xSeenCount: id.count)
    }

    /// One documented success, so there is no status to choose — only the header the document requires.
    @Operation
    func taskVersion(
        @Path id: String
    ) async throws -> (headers: Operations.TaskVersion.Output.Ok.Headers, body: Components.Schemas.Task) {
        (.init(eTag: "\"v1-\(id)\""), .init(id: id, title: "task-\(id)"))
    }
}

// The documented successes of each operation that chooses its status per call, each case carrying the
// generated headers its response declares. WireOpenAPIGen checks both against the document.

extension Operations.RegisterTask {
    enum SuccessStatus: Sendable, Hashable {
        case ok(Operations.RegisterTask.Output.Ok.Headers)
        case created(Operations.RegisterTask.Output.Created.Headers)
    }
}

extension Operations.TouchTask {
    enum SuccessStatus: Sendable, Hashable {
        case accepted(Operations.TouchTask.Output.Accepted.Headers)
        case noContent
    }
}
