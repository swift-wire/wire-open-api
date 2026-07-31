// swift-tools-version: 6.3
import CompilerPluginSupport
import PackageDescription

// WireOpenAPI — a cross-runtime Wire adapter for swift-openapi-generator. It collates
// `@OpenAPIController` controllers into a handlers key, has Wire emit a `TransportComposable`
// conformance on the generated graph, and registers the collated handlers onto a user-owned
// `some ServerTransport` that stays outside the graph. Depends only on OpenAPIRuntime — no
// HTTP framework — so a wired controller mounts on Hummingbird, Vapor, or Lambda unchanged.
//
// Depends on pushed swift-wire main. `WireOpenAPIExample` is the runnable end-to-end
// validation — it applies swift-wire's build plugin, wiring an `@OpenAPIController` controller
// onto a recording transport.
let package = Package(
    name: "wire-open-api",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WireOpenAPI", targets: ["WireOpenAPI"]),
        // A consumer applies this INSTEAD of swift-wire's WireBuildPlugin: it runs WireGen for the graph
        // and the contributor-proxy structs, then WireOpenAPIGen for those proxies' witnesses.
        .plugin(name: "WireOpenAPIBuildPlugin", targets: ["WireOpenAPIBuildPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", "603.0.0"..<"604.0.0"),
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
            ]
        ),
        // The domain half of the codegen — fills the body hole WireGen leaves on each aggregate proxy.
        .executableTarget(
            name: "WireOpenAPIGen",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .plugin(
            name: "WireOpenAPIBuildPlugin",
            capability: .buildTool(),
            dependencies: [
                "WireOpenAPIGen",
                .product(name: "WireGen", package: "swift-wire"),
            ]
        ),
        .executableTarget(
            name: "WireOpenAPIExample",
            dependencies: [
                "WireOpenAPI",
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            plugins: [.plugin(name: "WireOpenAPIBuildPlugin")]
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
