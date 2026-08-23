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
        var dependencyGroups:
            [(
                module: String, sources: [URL], specs: [URL], configs: [URL], settings: [URL],
                isExternal: Bool
            )] = []
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
                // A dependency may own a whole document — its own generated `APIProtocol` and the
                // controllers implementing it. That is how one app serves two specs, so its document is
                // read from there rather than expected in this target.
                dependencyGroups.append(
                    (
                        dependencyModule.moduleName,
                        dependencySources,
                        openAPIDocuments(in: dependencyModule),
                        openAPIConfigs(in: dependencyModule),
                        wireSettings(in: dependencyModule),
                        isExternal
                    )
                )
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
        // The document itself, so the generated witness can name its server prefix. A *source* file of
        // the target, never the OpenAPI generator's output — reading that would be an undeclared input.
        let specs = openAPIDocuments(in: sourceModule)
        let specSettings = wireSettings(in: sourceModule)
        // The generator's own config, for `namingStrategy`: it decides the spelling of every generated
        // symbol the typed shim names, and its default is defensive rather than idiomatic.
        let specConfigs = openAPIConfigs(in: sourceModule)

        // Built up in statements rather than one `+` chain: the chain grew a term too long for the
        // type checker, which then failed with "unable to type-check this expression in reasonable
        // time" — an error SwiftPM swallows entirely unless you pass `--verbose`.
        var openAPIGenArguments: [String] = [handlersURL.path]
        for spec in specs { openAPIGenArguments += ["--spec", spec.path] }
        // `--spec-module <module> <document>`: this spec's generated types are that module's, so
        // `@OpenAPIController(spec: "<module>")` names it and the emitted conformer qualifies against it.
        for group in dependencyGroups {
            for spec in group.specs { openAPIGenArguments += ["--spec-module", group.module, spec.path] }
        }
        for config in specConfigs { openAPIGenArguments += ["--spec-config", config.path] }
        for group in dependencyGroups {
            for config in group.configs {
                openAPIGenArguments += ["--spec-module-config", group.module, config.path]
            }
        }
        for settings in specSettings { openAPIGenArguments += ["--spec-settings", settings.path] }
        for group in dependencyGroups {
            for settings in group.settings {
                openAPIGenArguments += ["--spec-module-settings", group.module, settings.path]
            }
        }
        for group in dependencyGroups { openAPIGenArguments += ["--import", group.module] }
        openAPIGenArguments += ["--module", sourceModule.moduleName]
        openAPIGenArguments += swiftSources.map(\.path)
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
                // The spec is an input, not just an argument: without it a spec-only edit re-runs
                // swift-openapi-generator and not this tool, so the emitted `serverURL` — and, later, any
                // spec-derived diagnostic — would be computed against the previous document. Spike-28
                // recorded exactly this hazard; the fix is one line and easy to omit.
                inputFiles: allInputFiles + specs + specConfigs + specSettings
                    + dependencyGroups.flatMap(\.specs) + dependencyGroups.flatMap(\.configs)
                    + dependencyGroups.flatMap(\.settings),
                outputFiles: [handlersURL]
            ),
        ]
    }
}

/// A module's OpenAPI documents: *source* files of the target, never the generator's emitted Swift, which
/// would be an undeclared build input (spike-28, finding 1). The generator's own config is not one.
private func openAPIDocuments(in module: SourceModuleTarget) -> [URL] {
    module.sourceFiles
        .map(\.url)
        .filter {
            ["yaml", "yml", "json"].contains($0.pathExtension)
                && $0.lastPathComponent != "openapi-generator-config.yaml"
                && $0.lastPathComponent != wireSettingsFileName
        }
}

/// The adapter's own per-document settings file, beside the document it configures.
///
/// A file of ours rather than a key in `openapi-generator-config.yaml`: that config belongs to
/// swift-openapi-generator, and it *rejects* unknown keys outright — adding one there fails the
/// generator before this tool ever runs. Declared as an input, so turning a setting on re-runs the
/// codegen rather than leaving stale output in place.
let wireSettingsFileName = "wire-openapi.yaml"

private func wireSettings(in module: SourceModuleTarget) -> [URL] {
    module.sourceFiles
        .map(\.url)
        .filter { $0.lastPathComponent == wireSettingsFileName }
}

/// A module's swift-openapi-generator config. Read for `namingStrategy`, and declared as an input so a
/// change of strategy re-runs this tool rather than only the generator.
private func openAPIConfigs(in module: SourceModuleTarget) -> [URL] {
    module.sourceFiles
        .map(\.url)
        .filter { $0.lastPathComponent == "openapi-generator-config.yaml" }
}
