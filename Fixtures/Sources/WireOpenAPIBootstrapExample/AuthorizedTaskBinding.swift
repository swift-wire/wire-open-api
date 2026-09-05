// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import HTTPTypes
import Wire
import WireMVC

/// A **graph-aware** request binding on an OpenAPI operation.
///
/// The document describes the *wire*, and an authorised task never crosses it: what the caller sends is an
/// id, which `@Path` already binds. The `Task` this produces is resolved server-side — a store read and a
/// decision — so no `parameters:` entry could describe it and the generated `Input` has no member for it.
/// That is why the typed shim binds it by calling the worker instead of projecting it, and why the
/// generator excuses it from the document match rather than reporting a parameter the document forgot.
///
/// Two types, for the reason wire-mvc's own bindings are: a parameter attribute has to be a property
/// wrapper, whose instance holds the value the call site supplies, while a graph binding's instance holds
/// the dependencies the graph supplied. Neither initialiser could be total on one type.
@RequestBinding(TaskAuthorizer.self)
@propertyWrapper
struct AuthorizedTask {
    var wrappedValue: Components.Schemas.Task
    init(wrappedValue: Components.Schemas.Task) { self.wrappedValue = wrappedValue }
    init(wrappedValue: Components.Schemas.Task, _ name: String) { self.wrappedValue = wrappedValue }
}

/// The worker: an ordinary `@Scoped(seed:)` binding, in the same scope `TaskController` enters.
///
/// It injects `RequestIdentity` — a request-scoped binding — which is the whole point: a static `bind`
/// could not reach it, and that is what a graph-aware binding is for.
@Scoped(seed: HTTPRequest.self)
struct TaskAuthorizer: ScopedRequestBound {
    typealias Value = Components.Schemas.Task

    @Inject let identity: RequestIdentity

    func bind(
        name: String,
        request: HTTPTypes.HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> Components.Schemas.Task {
        let id = pathParameters["id"].map(String.init) ?? ""
        // `secret-` stands in for a policy decision. What matters is that it happens here, between the
        // request and the handler's parameter — so the operation cannot serve an unauthorised task.
        guard !id.hasPrefix("secret-") else { throw TaskForbidden(action: name, id: id) }
        return .init(id: id, title: "authorized \(id) via \(identity.path)", at: fixtureDate)
    }
}

/// Thrown by the worker, mapped by the operation's `@ErrorResponse` to the 403 the document declares.
struct TaskForbidden: Error {
    let action: String
    let id: String
}
