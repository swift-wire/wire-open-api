import Foundation
import PackagePlugin

/// `WireOpenAPIBuildPlugin` — the adapter-owned build plugin a WireOpenAPI consumer applies **instead of**
/// swift-wire's `WireBuildPlugin`. It runs two tools over one source set, both emitting into this module:
///
///   • `WireGen` (swift-wire) — the graph, the key checks, and the contributor-proxy structs, including
///     the aggregate `_WireOpenAPIContributor[_<Spec>]` that `@OpenAPIController` directs;
///   • `WireOpenAPIGen` (this package) — the `TransportContributor` conformance on those proxies.
///
/// Orchestration is domain knowledge ("OpenAPI controllers need a witness generator"), so it lives with
/// the adapter and WireGen stays structural — the same split spike-23 settled for WireMVC.
@main
struct WireOpenAPIBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let sourceModule = target.sourceModule else { return [] }
        let swiftSources = sourceModule.sourceFiles(withSuffix: "swift").map(\.url)
        guard !swiftSources.isEmpty else { return [] }

        let wireGen = try context.tool(named: "WireGen")
        let openAPIGen = try context.tool(named: "WireOpenAPIGen")

        let graphURL = context.pluginWorkDirectoryURL.appendingPathComponent("_WireGraph.swift")
        let keyChecksURL = context.pluginWorkDirectoryURL.appendingPathComponent("_WireKeyChecks.swift")
        let handlersURL = context.pluginWorkDirectoryURL.appendingPathComponent("_WireOpenAPIHandlers.swift")

        // Cross-module composition, the same rule swift-wire's own plugin applies: re-parse the sources of
        // every Wire-aware dependency (one that ships a `_WireExports.swift` marker) so its bindings and
        // controllers compose into this consumer. Both tools read the same set — a controller may live in a
        // shared library while its proxy is emitted here.
        var dependencyGroups: [(module: String, sources: [URL], isExternal: Bool)] = []
        var seenModules: Set<String> = []
        for dependency in target.dependencies {
            let dependencyTargets: [Target]
            let isExternal: Bool
            switch dependency {
            case .target(let dependencyTarget):
                dependencyTargets = [dependencyTarget]
                isExternal = false
            case .product(let dependencyProduct):
                dependencyTargets = dependencyProduct.targets
                isExternal = true
            @unknown default:
                dependencyTargets = []
                isExternal = false
            }
            for dependencyTarget in dependencyTargets {
                guard let dependencyModule = dependencyTarget.sourceModule,
                    !seenModules.contains(dependencyModule.moduleName)
                else { continue }
                let dependencySources = dependencyModule.sourceFiles(withSuffix: "swift").map(\.url)
                guard dependencySources.contains(where: { $0.lastPathComponent == "_WireExports.swift" })
                else { continue }
                seenModules.insert(dependencyModule.moduleName)
                dependencyGroups.append((dependencyModule.moduleName, dependencySources, isExternal))
            }
        }

        let allInputFiles = swiftSources + dependencyGroups.flatMap(\.sources)
        let testingVariants = sourceModule.kind == .test ? ["--testing-variants"] : []

        var wireGenArguments =
            [graphURL.path, keyChecksURL.path] + testingVariants
            + ["--module", sourceModule.moduleName] + swiftSources.map(\.path)
        for group in dependencyGroups {
            wireGenArguments +=
                [group.isExternal ? "--external-module" : "--module", group.module]
                + group.sources.map(\.path)
        }

        // Each re-parsed Wire-aware dependency becomes an `--import`, so the emitted conformances — which
        // compile in *this* module — can name a controller declared in a shared library.
        var openAPIGenArguments =
            [handlersURL.path]
            + dependencyGroups.flatMap { ["--import", $0.module] }
            + ["--module", sourceModule.moduleName] + swiftSources.map(\.path)
        for group in dependencyGroups {
            openAPIGenArguments += ["--module", group.module] + group.sources.map(\.path)
        }

        return [
            .buildCommand(
                displayName: "WireGen \(target.name)",
                executable: wireGen.url,
                arguments: wireGenArguments,
                inputFiles: allInputFiles,
                outputFiles: [graphURL, keyChecksURL]
            ),
            .buildCommand(
                displayName: "WireOpenAPIGen \(target.name)",
                executable: openAPIGen.url,
                arguments: openAPIGenArguments,
                inputFiles: allInputFiles,
                outputFiles: [handlersURL]
            ),
        ]
    }
}
