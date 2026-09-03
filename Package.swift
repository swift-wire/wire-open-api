// swift-tools-version: 6.4
import CompilerPluginSupport
import PackageDescription

// WireOpenAPI — a cross-runtime Wire adapter for swift-openapi-generator. It collates
// `@OpenAPIController` controllers onto one aggregate proxy per spec and mounts that spec's operations
// as WireMVC routes, so an operation serves under the same router, `@NotFound`, error tiers and
// composition root as an annotation-driven `@Get`.
//
// Depends on pushed swift-wire main. The end-to-end validation lives in the `Fixtures` package, which
// runs the real swift-openapi-generator and serves over HTTP — the stand-in example that used to sit
// here proved less than the fixture does and could not survive per-operation dispatch.
// The same list wire-mvc's `proposalSettings` carries, verbatim — this package's API is compiled with
// them and its consumers already are, so agreeing is the whole point. It requires a Swift 6.4 toolchain.
//
// **Applied to the runtime targets and their tests, not to the tooling**, which is also wire-mvc's split:
// its macro plugin, codegen library, codegen executable and their tests carry none of this, and the same
// targets here carry none either. They are host-side SwiftSyntax programs that emit text; nothing about
// their compilation reaches a consumer, and `InternalImportsByDefault` in particular is only noise there —
// a macro plugin's public `PeerMacro` conformance would have to publicly import `SwiftSyntaxMacros` to
// satisfy a rule that protects an API surface these targets do not have.
//
// **`NonisolatedNonsendingByDefault`** is the one that was actually costing something, and wire-open-api
// was the one link in the chain without it: swift-wire and wire-mvc enable it on every target, this
// package's own `Fixtures` enable it, and the library they all meet in did not. A bare
// `@Sendable () async -> …` written here therefore meant `@concurrent`, while the identical spelling in
// the generated code this package hands types to meant `nonisolated(nonsending)`. That is the shape that
// already cost a day upstream: `WireScopeEntry` shipped a teardown requirement, swift-wire's own suite
// passed because a package agrees with itself, and the emitted conformance was refused in a consumer.
//
// Nothing here needed it — `WireOpenAPIRoutes.invoke` and its neighbours used to spell
// `nonisolated(nonsending)` by hand, which is what this mismatch looks like when you meet it one
// declaration at a time rather than as a rule. Those spellings are gone: they are provably redundant (the
// mangled symbols are byte-identical with and without them), and keeping a restatement of the default
// implies the neighbours differ. Under this feature the thing worth spelling is `@concurrent`, and nothing
// here wants it — which is also wire-mvc's convention, where no `func` declaration carries the annotation.
//
// Two things about adopting it, both measured rather than assumed:
//
// - **Source compatibility is not at risk.** One public async function type changes meaning — `invoke`'s
//   `handler:`. It only ever receives a closure *literal* from generated code, and a literal is typed by
//   its context, so no consumer's own default reaches it. And there is no consumer with the feature off:
//   turning it off in the fixtures fails on `Middleware`, whose `intercept` requirement is
//   `nonisolated(nonsending)` because wire-mvc enables this, so an app folding middleware already had to.
// - **It changes mangled symbols.** A consumer with a warm build directory gets an undefined-symbol link
//   error naming these functions rather than a rebuild. `swift package clean` is the whole fix, and it is
//   worth expecting rather than debugging — the fixtures did exactly this here.
//
// The rest cost one change each and no behaviour: `InternalImportsByDefault` made `Wire`, `HTTPAPIs`,
// `HTTPTypes` and `OpenAPIRuntime` public imports where the runtime's own public signatures name them,
// and `MemberImportVisibility` made one test target import `OpenAPIRuntime` for the members it reads.
// `ExistentialAny`, `strictMemorySafety` and the lifetime features needed nothing: the sources already
// satisfied them.
let wireOpenAPISettings: [SwiftSetting] = [
    .strictMemorySafety(),
    .enableExperimentalFeature("SuppressedAssociatedTypesWithDefaults"),
    .enableExperimentalFeature("LifetimeDependence"),
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("LifetimeDependence"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "wire-open-api",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WireOpenAPI", targets: ["WireOpenAPI"]),
        // A consumer applies this INSTEAD of swift-wire's WireBuildPlugin: it runs WireGen for the graph
        // and the contributor-proxy structs, then WireOpenAPIGen for those proxies' witnesses.
        .plugin(name: "WireOpenAPIBuildPlugin", targets: ["WireOpenAPIBuildPlugin"]),
        // The domain half alone, for an app that uses more than one adapter — see the plugin's own note.
        .plugin(name: "WireOpenAPIGenPlugin", targets: ["WireOpenAPIGenPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        // The 6.4 line, matching wire-mvc: SPM version ranges don't resolve pre-release tags, and the
        // branch pin also overrides swift-wire's transitive 603 requirement.
        .package(url: "https://github.com/swiftlang/swift-syntax", branch: "release/6.4.x"),
        // Reads the document's `servers:` block — the only part of the spec the codegen needs today.
        // The same parser swift-openapi-generator uses, and JSON is valid YAML, so `openapi.json` works.
        // Pinned to the range swift-openapi-generator uses, so a consumer resolving both does not end up
        // with two OpenAPIKits. Reading the document with the same model the generator reads it with is
        // the point: `$ref`s, path-level parameters and `default` responses are then handled once, by a
        // library, rather than by a dictionary walk that silently drops what it does not recognise.
        .package(url: "https://github.com/mattpolzin/OpenAPIKit", from: "6.1.0"),
        .package(url: "https://github.com/jpsim/Yams.git", "4.0.0"..<"7.0.0"),
        // An `@Operation` is collated as a WireMVC route — it contributes to
        // `WireMVCKeys.routeContributors` like a `@Get` does — so wire-mvc is a core dependency. It is
        // proposal-native (tools 6.4, macOS 26), which is why this package is too.
        // `ServerTransport` trait: serving the collated routes on Hummingbird/Vapor/Lambda goes through
        // `WireMVCServerTransport`, which the trait gates.
        .package(
            url: "https://github.com/tachyonics/wire-mvc.git",
            branch: "main",
            traits: [.defaults, "ServerTransport"]
        ),
    ],
    targets: [
        .macro(
            name: "WireOpenAPIMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "WireOpenAPI",
            dependencies: [
                "WireOpenAPIMacros",
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                // Operations are collated as WireMVC routes, so the routing surface is a core
                // dependency rather than an opt-in module.
                .product(name: "WireMVC", package: "wire-mvc"),
            ],
            swiftSettings: wireOpenAPISettings
        ),
        // The domain half of the codegen — fills the body hole WireGen leaves on each aggregate proxy.
        // The copied naming transform, alone in its own target so the copy is obvious and so tests can
        // reach it — `WireOpenAPIGen` is an executable and cannot be imported.
        .target(name: "WireOpenAPINaming"),
        // Regenerates the naming golden table by running the real generator. A tool rather than a test
        // so it can run the generator as a subprocess: linking it would pull the generator and OpenAPIKit
        // into this package's resolution for one check.
        .executableTarget(
            name: "NamingGoldenTool",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        // Gates the diagnostics WireOpenAPIGen *rejects* with — the half the fixture cannot cover, since
        // it proves only what builds. A subprocess tool rather than a test for the reason NamingGoldenTool
        // is one: the contract under test is an exit code and a stderr message, which is what a caller
        // actually sees, and an executable cannot be imported to assert it any other way.
        .executableTarget(name: "DiagnosticGoldenTool", exclude: ["diagnostics-golden.txt"]),
        .executableTarget(
            name: "WireOpenAPIGen",
            dependencies: [
                "WireOpenAPINaming",
                .product(name: "OpenAPIKit", package: "OpenAPIKit"),
                .product(name: "OpenAPIKit30", package: "OpenAPIKit"),
                .product(name: "OpenAPIKitCompat", package: "OpenAPIKit"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .plugin(
            name: "WireOpenAPIGenPlugin",
            capability: .buildTool(),
            dependencies: ["WireOpenAPIGen"]
        ),
        .plugin(
            name: "WireOpenAPIBuildPlugin",
            capability: .buildTool(),
            dependencies: [
                "WireOpenAPIGen",
                .product(name: "WireGen", package: "swift-wire"),
            ]
        ),
        .testTarget(name: "WireOpenAPINamingTests", dependencies: ["WireOpenAPINaming"]),
        // The runtime's own logic — the status rule and the failure cap — which is decided rather than
        // walked, so it is worth asserting directly instead of only through the fixture's HTTP round-trip.
        .testTarget(
            name: "WireOpenAPITests",
            dependencies: [
                "WireOpenAPI",
                // Named directly because `MemberImportVisibility` makes this file import what it names:
                // the failure's `httpBody` and `HTTPBody` are the OpenAPI runtime's, not WireOpenAPI's.
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            swiftSettings: wireOpenAPISettings
        ),
        .testTarget(
            name: "WireOpenAPIMacrosTests",
            dependencies: [
                "WireOpenAPIMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
