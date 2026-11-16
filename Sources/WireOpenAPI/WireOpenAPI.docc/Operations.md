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
201 with a new resource, or 200 with the one a natural key already names. For those, return
WireMVC's **response tuple**, the same labelled tuple a `@Post` route returns:

```swift
@Operation
func registerTask(@Query id: String) async throws
    -> (status: Operations.RegisterTask.SuccessStatus, headers: HTTPFields, body: Task)
{
    let (task, created) = try store.register(id)
    return created
        ? (.created, [.location: "/tasks/\(id)"], task)
        : (.ok, [.eTag: task.version], task)
}

extension Operations.RegisterTask {
    enum SuccessStatus: Sendable, Hashable, CaseIterable {
        case ok
        case created
    }
}
```

The shapes are WireMVC's: `(status:body:)`, `(status:headers:body:)`, `(status:headers:)` for
an operation whose successes carry no body, and `(headers:body:)` when there is no status to
choose but the response declares headers. They are read by label, in that order.

**The status is an enum of the document's successes.** It is not `HTTPResponse.Status`, the type
a WireMVC route's tuple uses: that would let the handler return a status the document does not
declare, so it is a build-time error that names the enum to declare instead. You declare the enum
yourself, beside the controller, with one case per success the document declares for the
operation, named as the generated `Output` cases are (`ok`, `created`, `noContent`). The build
checks the cases are exactly those. Nesting it as `Operations.<Operation>.SuccessStatus` is the
convention the diagnostics suggest, and swift-openapi-generator emits nothing by that name. Any
plain enum the build can read is accepted.

That leaves a status the document does not declare as something the handler cannot write, so the
compiler refuses it (`type 'Operations.RegisterTask.SuccessStatus' has no member 'accepted'`). The
generated forwarder switches over the enum with no `default`. This is argued from how the pieces
fit, not machine-verified. The package has no harness that asserts a build fails, so the compiler
error above was checked once by hand.

The build also checks that there is more than one success to choose between, that they all agree
on whether they carry a body, and that no annotation names a status as well.

**Headers go into the response's declared headers.** The generated response carries them as
typed members, so a returned field fills the member for the header of that name, matched
case-insensitively. A field the chosen response does not declare, or a required header the
fields leave out, throws `WireOpenAPIUndocumentedResponse`: the first has no member to go
in, and the second has nothing honest to put in its member. Only a header with a plain `string`
schema can be built from a field value. A header typed as anything else is a build-time error
when the handler returns fields, and a required header is a build-time error when it returns none.

The serializer the generator emits writes a typed header value with URI coding, so a `/` or a
`"` in a returned value goes out percent-encoded (`/tasks/1` as `%2Ftasks%2F1`). That is the
generator's behaviour for every typed response header, not something the tuple adds.

**An undocumented header is the service's fault, so it is always 500 with no body.** The
caller did nothing wrong. Like a response that fails validation, it is rethrown past every
`@ErrorResponse` clause, so a catch-all written to answer bad requests cannot answer it with a
client-error status.

This answers the objection the closure form of `@ErrorResponse` meets: a status chosen from a
value cannot be checked against the document. A response tuple does not choose freely. Its status
is an enum whose cases the build holds to the document's successes, and its header fields are
checked against the chosen response before anything is sent.

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
