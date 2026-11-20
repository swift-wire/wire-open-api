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

## Choosing the response at run time

Which response an operation answers with is the document's to declare. When it declares one
success, a typed handler answers with it. When it declares several, the handler names one with
`@JSONResponse(status:)` or `@ResponseStatus(_:)` — once, for every call.

Some operations cannot decide that until the handler has run. Find-or-create is the common one:
201 with a new resource, or 200 with the one a natural key already names. For those, return a
**status enum** of the operation's documented successes beside the body, in WireMVC's
`(status:body:)` tuple:

```swift
@Operation
func registerTask(@Query id: String) async throws
    -> (status: Operations.RegisterTask.SuccessStatus, body: Task)
{
    let (task, created) = try store.register(id)
    return created
        ? (.created(.init(location: "/tasks/\(id)")), task)
        : (.ok(.init(eTag: task.version)), task)
}

extension Operations.RegisterTask {
    enum SuccessStatus: Sendable, Hashable {
        case ok(Operations.RegisterTask.Output.Ok.Headers)
        case created(Operations.RegisterTask.Output.Created.Headers)
    }
}
```

You declare the enum yourself, beside the controller. It has one case per success the document
declares for the operation, named as the generated `Output` cases are (`ok`, `created`,
`noContent`). A case whose response declares headers carries that response's generated
`Headers` as its one associated value; a case whose response declares none carries nothing.
The build checks both against the document, and its errors name the declaration to write.
Nesting it as `Operations.<Operation>.SuccessStatus` is the convention they suggest, and
swift-openapi-generator emits nothing by that name.

**Neither a status nor a header the document does not declare can be written.** The enum has no
case for an undocumented status, so the compiler refuses one
(`type 'Operations.RegisterTask.SuccessStatus' has no member 'accepted'`). A case's headers are
the generated type, so it has no member for an undeclared header either
(`extra argument 'cacheControl' in call`), and a required header is a required argument. The
generated forwarder switches over the enum with no `default` and passes each case's headers
straight into the generated response, so nothing about the status or the headers is checked at
run time. Because the headers are the generated type, a header of any schema works: an
`integer` header is an `Int` member, set as one. This is argued from how the pieces fit, not
machine-verified. The package has no harness that asserts a build fails, so the two compiler
errors above were checked once by hand.

When there is no status to choose but the one success declares headers, return its generated
`Headers` beside the body, as `(headers:body:)`:

```swift
@Operation
func taskVersion(@Path id: String) async throws
    -> (headers: Operations.TaskVersion.Output.Ok.Headers, body: Task)
```

A response declared under `components/responses` and referenced is named from its component
instead, as the generator names it: `Components.Responses.<Name>.Headers`.

Swift has no one-element labelled tuple, so an operation whose successes carry no body returns
the enum, or the generated `Headers`, on its own:

```swift
@Operation
func touchTask(@Path id: String) async throws -> Operations.TouchTask.SuccessStatus {
    id == "later" ? .accepted(.init(retryAfter: 30)) : .noContent
}
```

The return is read as a status when it names an enum declared in the sources the build reads, and
as headers when it is spelled as a generated `Headers` type. Anything else is the body. Free
`HTTPFields`, `HTTPResponse.Status`, and WireMVC's `(status:headers:body:)` and
`(status:headers:)` are build-time errors naming the type to return instead: each would let the
handler send something its document does not declare.

The build also checks that there is more than one success to choose between, that they all agree
on whether they carry a body, and that no annotation names a status as well.

The serializer the generator emits writes a typed header value with URI coding, so a `/` or a
`"` in a header value goes out percent-encoded (`/tasks/1` as `%2Ftasks%2F1`). That is the
generator's behaviour for every typed response header, not something these forms add.

This answers the objection the closure form of `@ErrorResponse` meets: a status chosen from a
value cannot be checked against the document. A status enum does not choose freely. Its cases and
their headers are held to the document's successes when the code is built.

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
