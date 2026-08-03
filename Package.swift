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
        .package(url: "https://github.com/jpsim/Yams.git", "4.0.0"..<"7.0.0"),
        // Operations are collated as WireMVC routes (M6d.1b), so wire-mvc is a core dependency. It is
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
            ]
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
        .executableTarget(
            name: "WireOpenAPIGen",
            dependencies: [
                "WireOpenAPINaming",
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
        .testTarget(
            name: "WireOpenAPIMacrosTests",
            dependencies: [
                "WireOpenAPIMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
