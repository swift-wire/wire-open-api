# Scope and error handling

Where an operation's errors are mapped, and the one thing a request-scoped controller has to
write at controller scope.

## Overview

Error mapping is WireMVC's `@ErrorResponse`, at the scopes it always has: the composition root
for every route, the controller for its operations, the operation itself for one. Nothing here is
OpenAPI-specific.

One case is, and it is worth understanding before you write a request-scoped OpenAPI controller.

## A scope that refuses

Entering a request scope happens in the **route terminal** rather than in the generated
forwarder. It has to: the entry is what produces the subject the forwarder is built around, and
the scope has to outlive the response so that teardown runs after it.

The consequence is that a `@Scoped(seed:)` binding which throws while the scope is built is
*outside* every `catch` the forwarder emits. So the terminal branches on that failure and answers
it with the mappings written on the controller:

```swift
@Scoped(seed: HTTPRequest.self)
@OpenAPIController
@ErrorResponse(Unauthenticated.self, .unauthorized, { _ in Problem(message: "no user") })
struct GatedTaskController {
    @Inject let gate: RequestGate       // throws while the scope is built
    @Operation func gatedTask(@Path id: String) async throws -> Task { … }
}
```

## Why controller scope is the only place to write it

One scope entry serves every operation the controller implements, so a failure entering it is not
attributable to any one of them. There is no operation to hang the mapping on.

That interacts with a rule the adapter already had: a controller-scope mapping's status must be
declared by *every* operation on the controller. Here that rule is what makes the answer one the
document describes, whichever operation was asked for.

And for a scoped controller it holds **even where an operation maps the same error itself** —
scope entry precedes dispatch, so the shadowing forwarder never runs. An operation-scope mapping
for an error thrown at scope entry is dead code, and the controller-scope one is the live answer.

## Validation failures

A request the document describes as invalid is a different case: it is thrown inside the
forwarder, where the operation's typed input exists, so it maps like any other error the handler
could throw. See <doc:SchemaValidation>.
