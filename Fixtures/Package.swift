// swift-tools-version: 6.4
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import PackageDescription

// wire-open-api's runnable fixture — a `@WireMVCBootstrap` app that serves an OpenAPI operation and an
// annotation-driven `@Get` route from **one router**, over real HTTP.
//
// It lives in its own package, alongside the framework rather than inside it, for the reason wire-mvc's
// fixtures do: it serves on `NIOHTTPServer`, and anything naming `swift-http-server` unconditionally in
// wire-open-api's manifest would put the whole NIO stack into every downstream consumer's
// `Package.resolved`. SwiftPM prunes a package dependency only when its every product dependency sits
// behind an off-by-default trait.
//
// It also runs the **real** swift-openapi-generator, which is the point: until now the bridge has only
// ever met a hand-written stand-in for `APIProtocol`. Here the generator's own deserializer reads the
// path parameters WireMVC matched, and its own serializer sets the response headers the terminal has to
// preserve — so this is the first thing that exercises `WireOpenAPIRoutes.invoke` at runtime.
//
// Run from this directory: `swift build`, `swift run WireOpenAPIBootstrapExample`.
// Everything below `InternalImportsByDefault`, which a module holding *public* generated code cannot
// have: swift-openapi-generator emits plain `import` lines, and a public method whose parameter types
// come from an internally-imported module does not compile. See the OrdersAPI target.
let generatedPublicAPISettings: [SwiftSetting] = [
    .strictMemorySafety(),
    .enableExperimentalFeature("SuppressedAssociatedTypesWithDefaults"),
    .enableExperimentalFeature("LifetimeDependence"),
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("LifetimeDependence"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let proposalSettings: [SwiftSetting] =
    generatedPublicAPISettings + [.enableUpcomingFeature("InternalImportsByDefault")]

let package = Package(
    name: "wire-open-api-fixtures",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: ".."),
        // Traits union across the graph: wire-open-api already asks for `ServerTransport`; the fixture
        // adds `NIOHTTPServer`, which is the only thing pulling `swift-http-server` in.
        .package(
            url: "https://github.com/tachyonics/wire-mvc.git",
            branch: "main",
            traits: [.defaults, "ServerTransport", "NIOHTTPServer"]
        ),
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
        // Fork, until the access change lands upstream: direct dispatch (`--request-scope=direct`) calls
        // the generated per-operation methods on `UniversalServer`, which stock swift-openapi-generator
        // emits `fileprivate`. The branch changes that one `accessModifier` to internal — enough, because
        // WireOpenAPIGen's output compiles into the same module. Points back at the released package once
        // upstream takes it.
        // **Pinned to a revision, not the branch.** A branch dependency re-resolves to whatever the fork's
        // tip happens to be, so a force-push or an unrelated commit there could change what this fixture
        // generates — and the fixture is the gate for the whole adapter. `swift-wire` is a working branch
        // on a fork nobody else watches, which is exactly the kind of reference that moves quietly.
        // Points back at the released package once upstream takes the change.
        .package(
            url: "https://github.com/tachyonics/swift-openapi-generator.git",
            revision: "9e655e0adb9b993ef4cb29a6aa0dfc59b9b42b09"
        ),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-http-api-proposal.git", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
        .package(url: "https://github.com/swift-server/swift-http-server.git", branch: "main"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.13.2"),
    ],
    targets: [
        // A second document, in its own module: its `openapi.yaml`, the types swift-openapi-generator
        // makes from it, and the controller implementing them. It runs only the OpenAPI generator —
        // WireGen runs once, in the app, and re-parses this module's sources because of its
        // dependency on the `Wire` product. That is what puts the proxy for this spec in the app.
        .target(
            name: "OrdersAPI",
            dependencies: [
                .product(name: "WireOpenAPI", package: "wire-open-api"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: generatedPublicAPISettings,
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        // Three plugins on one target, in this order: OpenAPIGenerator emits the spec's
        // types and `registerHandlers`, then WireOpenAPIBuildPlugin runs WireGen (graph + aggregate proxy)
        // and WireOpenAPIGen (the proxy's conformances).
        .executableTarget(
            name: "WireOpenAPIBootstrapExample",
            dependencies: [
                "OrdersAPI",
                .product(name: "WireOpenAPI", package: "wire-open-api"),
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCRouter", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "BasicContainers", package: "swift-collections"),
                .product(name: "NIOHTTPServer", package: "swift-http-server"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: proposalSettings,
            // Four plugins, none knowing about another. `WireBuildPlugin` emits the graph exactly once;
            // each adapter contributes only its own domain generator. This is the composition the
            // bundled per-adapter plugins cannot express — with those, applying one adapter's plugin
            // silently leaves the other adapter's witnesses ungenerated.
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
                .plugin(name: "WireBuildPlugin", package: "swift-wire"),
                .plugin(name: "WireMVCRouteGenPlugin", package: "wire-mvc"),
                .plugin(name: "WireOpenAPIGenPlugin", package: "wire-open-api"),
            ]
        ),
    ]
)
