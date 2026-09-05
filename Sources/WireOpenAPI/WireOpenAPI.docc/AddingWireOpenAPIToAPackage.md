# Adding WireOpenAPI to a package

The manifest, the two dependencies you need rather than one, and the plugin that replaces
swift-wire's.

## Overview

A consumer depends on **both** `WireOpenAPI` and `WireMVC`, directly. That is not redundancy:
swift-wire activates a dependency's keys only when it is a *direct* dependency, and the collation
key an operation contributes to is WireMVC's. Depending on WireOpenAPI alone leaves the key
unactivated and the routes uncollated.

## The manifest

```swift
dependencies: [
    .package(url: "https://github.com/tachyonics/wire-open-api.git", branch: "main"),
    .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main"),
],
targets: [
    .executableTarget(
        name: "App",
        dependencies: [
            .product(name: "WireOpenAPI", package: "wire-open-api"),
            .product(name: "WireMVC", package: "wire-mvc"),
            .product(name: "Wire", package: "swift-wire"),
        ],
        plugins: [.plugin(name: "WireOpenAPIBuildPlugin", package: "wire-open-api")]
    ),
]
```

## The plugin replaces swift-wire's

Apply `WireOpenAPIBuildPlugin`, **not** swift-wire's `WireBuildPlugin`. The adapter's plugin runs
both tools over one source set: `WireGen` for the graph and the contributor-proxy structs, then
`WireOpenAPIGen` for those proxies' route-contributor witnesses. Applying swift-wire's plugin as
well would generate the graph twice.

The same is true of wire-mvc's plugin — one build plugin drives the whole generation, so a target
applies exactly one.

## The generator's configuration

The module holding a document needs `accessModifier: public` in its swift-openapi-generator
config when its controllers or the app live elsewhere, because the generated `APIProtocol` and
operation types are referenced across the module boundary. It also needs a dependency on the
`Wire` product.

WireGen runs once, in the app, so that is where the proxy is emitted regardless of where the
document and its controllers live.

## Before you start

WireOpenAPI needs a forked swift-openapi-generator today — read <doc:TheForkedGenerator> before
committing to it, because the constraint is not one you can work around at the call site.

It requires a Swift 6.4 toolchain and targets macOS 26 and Linux, matching wire-mvc, which is
proposal-native.
