import Foundation
import OpenAPIKit
import SwiftParser
import SwiftSyntax
import Yams

// WireOpenAPIGen — the domain half of WireOpenAPI's codegen, the counterpart to WireMVC's
// `WireMVCRouteGen`.
//
// swift-wire's WireGen emits the *structural* half of the contributor proxy: the struct, its fields
// (`_wireSubject`, or `_wireSubject_<Subject>` when a group holds several), its initialiser, and
// `Sendable` — with a body hole. This tool fills that hole with the `RouteContributor` conformance that
// mounts the spec's operations as WireMVC routes.
//
// It cannot live in the `@OpenAPIController` macro. `RouteContributor` refines `Sendable`, and Swift
// requires a `Sendable` conformance in the type's own file, so the conformance can only be attached to a
// type declared in the same generated module — the proxy — which the macro cannot see.
//
// Usage: WireOpenAPIGen <output.swift> [--spec <openapi.yaml>] [--import <Module>]... [--module <Name> <source.swift>...]...
//
// The proxy is collated as a `RouteContributor` and nothing else: operations are routes, serving under
// the same router, `@NotFound`, error tiers and composition root as annotation-driven ones.

// MARK: - argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
guard let outputPath = arguments.first else {
    FileHandle.standardError.write(Data("WireOpenAPIGen: missing output path\n".utf8))
    exit(1)
}
arguments.removeFirst()

var imports: [String] = []
/// The document belonging to *this* target — the single-spec arrangement, where a spec's generated types
/// and the controllers implementing them compile into one module.
var localSpecPath: String?
/// Documents that live in a dependency module, keyed by that module's name. A `@OpenAPIController(spec:)`
/// value naming one of these says its generated `APIProtocol` is that module's, which is what lets an app
/// serve two documents whose generated types are spelled identically.
var moduleSpecPaths: [String: String] = [:]
/// The generator config beside each document, keyed the same way — `""` for this target's own.
var specConfigPaths: [String: String] = [:]
/// The adapter's own settings file beside each document, keyed the same way. A file of ours rather than
/// a key in the generator's config, which rejects unknown keys outright.
var specSettingsPaths: [String: String] = [:]
/// Sources grouped by the module that declares them, in the order the plugin passes them — this target
/// first, then each Wire-aware dependency. The grouping is what lets a bare `@OpenAPIController` mean
/// *the document beside this controller* rather than the document of whichever target happens to be
/// compiling it.
var sourceGroups: [(module: String, paths: [String])] = []
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--spec":
        index += 1
        if index < arguments.count { localSpecPath = arguments[index] }
    case "--spec-module":
        index += 2
        if index < arguments.count { moduleSpecPaths[arguments[index - 1]] = arguments[index] }
    case "--spec-config":
        index += 1
        if index < arguments.count { specConfigPaths[""] = arguments[index] }
    case "--spec-settings":
        index += 1
        if index < arguments.count { specSettingsPaths[""] = arguments[index] }
    case "--spec-module-settings":
        index += 2
        if index < arguments.count { specSettingsPaths[arguments[index - 1]] = arguments[index] }
    case "--spec-module-config":
        index += 2
        if index < arguments.count { specConfigPaths[arguments[index - 1]] = arguments[index] }
    case "--import":
        index += 1
        if index < arguments.count { imports.append(arguments[index]) }
    case "--module":
        index += 1
        if index < arguments.count { sourceGroups.append((arguments[index], [])) }
    default:
        // Sources follow the `--module` that names their module; anything before the first one would be
        // a caller error, and is attributed to no module rather than silently to this target.
        if sourceGroups.isEmpty { sourceGroups.append(("", [])) }
        sourceGroups[sourceGroups.count - 1].paths.append(arguments[index])
    }
    index += 1
}

let discovered = discoverControllers(in: sourceGroups)
/// The module being compiled — the first group the plugin passes. A controller declared here uses this
/// target's own document; one declared in a dependency uses that dependency's.
let localModule = sourceGroups.first?.module ?? ""

// MARK: - grouping

/// The proxy type swift-wire synthesises for a group — `_WireOpenAPIContributor` for the default group,
/// `_WireOpenAPIContributor_<Spec>` otherwise. Must match `aggregateProxyTypeName` in WireGenCore.
func proxyTypeName(for group: String) -> String {
    let sanitised = String(group.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    return "_WireOpenAPIContributor_\(sanitised)"
}

// The group a controller belongs to — always a module name. An explicit `spec:` names it outright;
// without one it is the controller's **home module**, the document sitting beside it.
//
// Resolving a bare annotation against the compiling target instead would make it mean something the
// author cannot see from the file they are reading: the answer would depend on which executable pulled
// the library in, and two libraries each shipping their own bare-annotated controllers would collide on
// one group. swift-wire's aggregate-proxy synthesis resolves identically, so the two agree on the proxy
// type without either needing to know which module is consuming.
var byGroup: [String: [DiscoveredController]] = [:]
for controller in discovered {
    byGroup[controller.spec ?? controller.homeModule, default: []].append(controller)
}

// MARK: - emission

// `WireOpenAPI` and `OpenAPIRuntime` are always needed (the conformance and the server it dispatches
// through); a Wire-aware dependency may name either, so the set is deduplicated rather than appended — a
// repeated import compiles but reads like a codegen bug.
//
// `UniversalServer` is `@_spi(Generated)`, the same import the generator's own `Server.swift` writes.
//
// A spec module is imported the same way. Its per-operation methods extend `UniversalServer`, and a
// member extending an SPI type is itself SPI however public it is declared — so a plain import of that
// module leaves them "inaccessible due to '@_spi' protection level".
let allImports = Set(["Foundation", "OpenAPIRuntime", "WireMVC", "WireOpenAPI"] + imports).sorted()
let spiImports = Set(moduleSpecPaths.keys).union(["OpenAPIRuntime"])
var lines: [String] = ["// Generated by WireOpenAPIGen — do not edit.", ""]
lines += allImports.map { spiImports.contains($0) ? "@_spi(Generated) import \($0)" : "import \($0)" }
lines.append("")

// A `@Middleware` fold. Each entry names a field Wire has already lifted onto the proxy: `T.self`
// injects the binding by type, a `FactoryKey` a synthesised factory whose `create` is specialised at the
// builder's box roles. Same spelling WireMVC's route codegen uses, so one `@Middleware(RequireAPIKey.self)`
// component serves an operation and a `@Get` alike.
//
// It is emitted at each registration rather than run from a helper because `wireCompose` returns the
// chain's concrete composed type — erasing it would stop the terminal reading the final box's contents.
func foldEntries(_ arguments: [String], indent: String) -> [String] {
    arguments.map { argument in
        if argument.hasSuffix(".self") {
            return indent + "self.\(dependencyPropertyName(forType: String(argument.dropLast(5))))"
        }
        return indent + "self._wireFactory_\(sanitizedKeyFragment(argument))"
            // Over the *unwrapped* context: the route's box is built after the courier is dropped.
            + ".create(Builder.RequestContext.Base.self, Builder.Reader.self, Builder.ResponseSender.self)"
    }
}

for (spec, controllers) in byGroup.sorted(by: { $0.key < $1.key }) where !controllers.isEmpty {
    // Two forms, one meaning each. The bare `@OpenAPIController()` is this target's own document —
    // generated here, so nothing needs qualifying. `@OpenAPIController(spec: "M")` says the generated
    // `APIProtocol` is module `M`'s, and M's document is the one to read.
    //
    // A `spec:` that resolves to nothing is an error, never a quiet fall back to the local document: the
    // fallback would compile against the wrong document and report it as a missing @RawOperation for
    // operations the author never wrote — or, with the right shape, mount the wrong routes.
    let specModule: String?
    let specPath: String?
    /// Loaded once per group: everything the codegen asks of the document goes through it.
    if spec == localModule {
        // This target's own document. Its generated types are local, so nothing needs qualifying.
        specModule = nil
        specPath = localSpecPath
    } else if let path = moduleSpecPaths[spec] {
        specModule = spec
        specPath = path
    } else {
        let known = moduleSpecPaths.keys.sorted()
        let available =
            known.isEmpty
            ? "This target depends on no module carrying an OpenAPI document."
            : "Modules carrying one: \(known.joined(separator: ", "))."
        let location = controllers[0]
        // Two ways to arrive here, and they need different advice. An explicit `spec:` naming nothing is a
        // typo or a missing dependency. A *bare* controller whose own module carries no document is the
        // other case entirely — the author wrote no module name, so quoting one back at them would be
        // baffling; what they need to know is that the bare form looks beside the controller.
        let message =
            controllers[0].spec == nil
            ? """
            \(location.file):\(location.line): error: '\(location.typeName)' is declared in module \
            '\(spec)', which carries no OpenAPI document — a bare @OpenAPIController implements the \
            document beside it. Put the document in '\(spec)', or name the module that owns the \
            generated APIProtocol with @OpenAPIController(spec: "..."). \(available)
            """
            : """
            \(location.file):\(location.line): error: @OpenAPIController(spec: "\(spec)") names the \
            module owning the generated APIProtocol, and no dependency of this target is called \
            '\(spec)'. \(available) For the document beside this controller, use the bare \
            @OpenAPIController().
            """
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
    let document = specPath.flatMap(loadDocument(at:))
    DirectDispatchEmitter(
        spec: spec,
        proxy: proxyTypeName(for: spec),
        controllers: controllers,
        specModule: specModule,
        operationRoutes: document?.operationRoutes(documentPath: specPath ?? "") ?? [:],
        componentSchemas: document?.componentAssertions(at: specPath ?? "") ?? [:],
        serverPrefix: resolveServerPrefix(document: document, path: specPath ?? ""),
        namingStrategy: resolveNamingStrategy(configPath: specConfigPaths[spec == localModule ? "" : spec]),
        settings: resolveWireSettings(path: specSettingsPaths[spec == localModule ? "" : spec]),
        foldEntries: foldEntries
    ).emit(into: &lines)
}

try (lines.joined(separator: "\n")).write(toFile: outputPath, atomically: true, encoding: .utf8)
