# Several specs in one app

One document per target, and the name collision that arrangement exists to solve.

## Overview

A second document lives in its own module — its `openapi.yaml`, the types
swift-openapi-generator makes from it, and optionally the controllers implementing them:

```swift
.target(
    name: "OrdersAPI",
    dependencies: [.product(name: "WireOpenAPI", package: "wire-open-api"), …],
    plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
)
```

That module needs `accessModifier: public` in its generator config and a dependency on the `Wire`
product. The app depends on it, and `@OpenAPIController(spec: "OrdersAPI")` names it. WireGen
still runs once, in the app, so that is where the proxy is emitted.

## The collision

The generator names its types from nothing about the document. **Every** spec module spells them
`APIProtocol`, `Operations`, `Servers`, `Components`.

So in an app importing two of them, a bare `Operations.GetOrder.Input` is "ambiguous for type
lookup" — including the spellings copied verbatim out of a controller that was perfectly
unambiguous where it was written. This is the hazard the per-spec arrangement has to answer.

## The generated namespace

The conformer is emitted inside a per-spec namespace whose typealiases resolve it:

```swift
enum _WireOpenAPISpec_OrdersAPI {
    typealias Operations = OrdersAPI.Operations
    …
    struct Conformer: APIProtocol { … }
}
```

So a controller writes its own document's types however it likes, qualified or not, and the
generated code is unambiguous regardless of how many documents the app imports.

An app may also generate one document itself and import another, because a module's own
declarations win over identically-spelled imported ones.

## What this means in practice

Nothing, at the call site — which is the point. You write controllers against the types as the
generator named them, and the ambiguity is resolved where the conformer is emitted rather than by
asking every author to qualify every reference.
