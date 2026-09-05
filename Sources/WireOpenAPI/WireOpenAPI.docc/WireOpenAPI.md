# ``WireOpenAPI``

Serve an OpenAPI document's operations as ordinary WireMVC routes, wired at build time.

## Overview

WireOpenAPI is a [swift-wire](https://github.com/tachyonics/swift-wire) adapter for
swift-openapi-generator. A controller conforming to a generated `APIProtocol` is marked
`@OpenAPIController`, and the build plugin collates every controller sharing a document onto one
generated proxy contributed to **`WireMVCKeys.routeContributors`** — the same key `@Controller`
uses.

```swift
@Singleton
@OpenAPIController
struct TaskController: APIProtocol {
    @Inject var repository: TaskRepository

    @Operation
    func getTask(@Path id: String) async throws -> Task { try repository.find(id) }
}
```

That shared key is the design, not an implementation note. **An operation is a route like any
other**: it serves under the same router, the same `@NotFound` fallback, the same `@ErrorResponse`
tiers, the same global middleware layer and the same composition root as an annotation-driven
`@Get`. Request scope, parameter binding and encoding are expressed identically whichever way the
route was authored. There is one routing model, not two.

## What it is not

**Not a runtime.** OpenAPI is a transport surface, so this adapter carries handlers and nothing
else — services and lifecycle stay with the runtime's own adapter, and the two coexist on one
graph. Serving is `WireMVCServerTransport.apply(graph, to: transport)`, the call a WireMVC app
already makes; there is deliberately no WireOpenAPI-specific facade. See <doc:ServingTheRoutes>.

## Topics

### Getting started

- <doc:AddingWireOpenAPIToAPackage>
- <doc:WritingAnOpenAPIController>
- <doc:Operations>

### Documents

- <doc:SharingASpec>
- <doc:SeveralSpecsInOneApp>

### Serving

- <doc:ServingTheRoutes>
- <doc:ScopeAndErrors>

### Validation

- <doc:SchemaValidation>
- ``WireOpenAPIFailure``
- ``WireOpenAPIFailureLocation``
- ``WireOpenAPIFailureAccumulator``
- ``WireOpenAPIRequestValidationError``
- ``WireOpenAPIResponseValidationError``
