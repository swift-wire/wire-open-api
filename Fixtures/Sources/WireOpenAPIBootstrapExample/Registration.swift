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

/// **Response tuples on typed operations.** Each handler says something about its response alongside
/// the body, in the same labelled tuple a WireMVC route returns — and the document decides which
/// responses those may be.
@Singleton
@OpenAPIController()
struct RegistrationController {
    @Inject let registry: TaskRegistry

    /// Find-or-create. The store decides whether the id is new, so the status is only known after the
    /// handler has run: 201 with a `Location` for a new task, 200 with an `ETag` for one already held.
    ///
    /// The status is `Operations.RegisterTask.SuccessStatus`, declared below with exactly the document's
    /// two successes, so the compiler refuses any status the document does not describe.
    ///
    /// `refused` throws, and the catch-all answers it with the document's 400 — which is what a catch-all
    /// is for. `stray` returns a field neither response declares, which is the service breaking its own
    /// contract: 500 with no body — and the catch-all here does not get to answer it, because the blame is
    /// the service's, not the caller's.
    @Operation
    @ErrorResponse(Swift.Error.self, .badRequest)
    func registerTask(
        @Query id: String
    ) async throws -> (
        status: Operations.RegisterTask.SuccessStatus, headers: HTTPFields, body: Components.Schemas.Task
    ) {
        let task = Components.Schemas.Task(id: id, title: "registered \(id)")
        struct Refused: Error {}
        switch id {
        case "refused": throw Refused()
        case "stray": return (.created, [.location: "/api/v1/tasks/\(id)", .cacheControl: "no-store"], task)
        default: break
        }
        return registry.register(id)
            ? (.created, [.location: "/api/v1/tasks/\(id)"], task)
            : (.ok, [.eTag: "\"\(id)\""], task)
    }

    /// The bodiless form: 204 when done at once, 202 when it is only queued.
    @Operation
    func touchTask(
        @Path id: String
    ) async throws -> (status: Operations.TouchTask.SuccessStatus, headers: HTTPFields) {
        (id == "later" ? .accepted : .noContent, [:])
    }

    /// One documented success, so there is no status to choose — only the header the document requires.
    @Operation
    func taskVersion(@Path id: String) async throws -> (headers: HTTPFields, body: Components.Schemas.Task) {
        ([.eTag: "\"v1-\(id)\""], .init(id: id, title: "task-\(id)"))
    }
}

// The documented successes of each operation that chooses its status per call. WireOpenAPIGen checks the
// cases against the document, named as the generated `Output` cases are.

extension Operations.RegisterTask {
    enum SuccessStatus: Sendable, Hashable, CaseIterable {
        case ok
        case created
    }
}

extension Operations.TouchTask {
    enum SuccessStatus: Sendable, Hashable, CaseIterable {
        case accepted
        case noContent
    }
}
