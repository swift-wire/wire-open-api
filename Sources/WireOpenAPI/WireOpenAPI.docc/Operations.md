# Operations

Two ways to implement an operation, and why each declares which one it is.

## Overview

An operation handler is a method on the controller, marked with the form that matches how you
want to receive the request.

**`@Operation` is the typed form.** The method takes the operation's parameters as ordinary Swift
arguments and returns its response body; the generated code binds the parameters from the
request and wraps the return value in the operation's response.

```swift
@Operation
func getTask(@Path id: String) async throws -> Task { try repository.find(id) }
```

**`@RawOperation` is the generated-shape form.** The method takes the generated
`Operations.X.Input` and returns its `Output`, exactly as `APIProtocol` declares it.

```swift
@RawOperation
func getTask(_ input: Operations.GetTask.Input) async throws -> Operations.GetTask.Output { … }
```

The two coexist per method, so a controller can migrate one operation at a time and keep the raw
form for anything the annotation set cannot express.

## The parameter vocabulary is WireMVC's

A typed operation binds its parameters with the **same** `@Path`, `@Query` and `@Header` wrappers a
WireMVC `@Get` route uses — the same types, not a parallel set. That is the whole point of the
unification: one binding vocabulary whether a route came from a document or from an annotation,
so what you learn on one applies to the other.

## Why identity is declared rather than inferred

Both attributes take an optional operation id, and bare they mean "the method's own name is the
operationId".

That is true by construction until the operationId is not a Swift identifier. The generated
protocol requirement is named from the operationId *after the generator's safe-name transform*,
which is identity for `getTask` and not for `get-task` or `list_tasks`. Recovering the id by
reversing that transform would quietly match nothing for any document whose operationIds are not
already Swift identifiers — and route-scope `@Middleware` on such a method would then silently
never apply.

So the renamed form declares it:

```swift
@Operation("get-task")
func getTask(@Path id: String) async throws -> Task { … }
```

This is the same resolution `@RawRoute`'s explicit roles and `@MiddlewareFactory`'s role mapping
reached in wire-mvc: where a name cannot be recovered reliably, it is stated rather than guessed.

## Conformance is the completeness check

Nothing here checks that you implemented every operation the document declares — `APIProtocol`
conformance already does, and it does it better. A controller missing an operation fails to
conform, and the compiler names it.
