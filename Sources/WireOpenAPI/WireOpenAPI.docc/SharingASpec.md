# Sharing a spec

Several controllers implementing one document, and what stays per controller.

## Overview

A document does not have to be one object's to serve. Operations are mounted individually, so
each controller contributes the operations it declares and the generated proxy holds them all.
`APIProtocol` conformance is what makes the compiler check the set adds up.

Declaring the same operationId twice is an error — an operation is mounted once.

## One proxy per document, not per controller

The aggregate follows the document. A spec's operations are implemented against one generated
`APIProtocol`, so one conformer per spec is the shape that mounts each operation exactly once.

That is why the proxy is aggregate where a WireMVC `@Controller`'s is per subject: the shape is
chosen by what the framework being adapted demands, and swift-wire's adapter contract carries
both.

## Scope and middleware stay per controller

The proxy holds or bridges each subject independently, so controllers sharing a document need not
share a lifetime or a middleware stack:

```swift
@Scoped(seed: HTTPRequest.self)
@OpenAPIController(spec: "TaskAPI")
@Middleware(RequireAPIKeyKeys.factory)
struct TaskController { @RawOperation func getTask(…) … }

@Singleton
@OpenAPIController(spec: "TaskAPI")
struct TaskListController { @RawOperation func listTasks(…) … }
```

`getTask` enters a request scope and folds `RequireAPIKey` around itself. `listTasks`, on the same
document, does neither.

A request enters only the scope of the controller owning the operation it dispatches, so nothing
is built that the request does not use — the same per-request reachability a WireMVC
request-scoped controller gets.

## Choosing how to split

Split by lifetime and policy rather than by document structure. Operations needing a request scope
or a middleware belong together on one controller; the rest can stay app-scoped, which is cheaper
per request. Because conformance is checked across the whole set, splitting costs nothing in
safety.
