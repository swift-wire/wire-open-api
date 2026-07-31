import Foundation
import SwiftParser
import SwiftSyntax

// WireOpenAPIGen — the domain half of WireOpenAPI's codegen, the counterpart to WireMVC's
// `WireMVCRouteGen`.
//
// swift-wire's WireGen emits the *structural* half of the contributor proxy: the struct, its fields
// (`_wireSubject`, or `_wireSubject_<Subject>` when a group holds several), its initialiser, and
// `Sendable` — with a body hole. This tool fills that hole with the `TransportContributor` conformance
// whose witness calls the OpenAPI generator's `registerHandlers`.
//
// It cannot live in the `@OpenAPIController` macro. `TransportContributor` refines `Sendable`, and Swift
// requires a `Sendable` conformance in the type's own file, so the conformance can only be attached to a
// type declared in the same generated module — the proxy — which the macro cannot see.
//
// Usage: WireOpenAPIGen <output.swift> [--import <Module>]... [--module <Name> <source.swift>...]...

/// One `@OpenAPIController` use-site: the controller's type name and the group (`spec:`) it declares.
/// The group matches swift-wire's `.contributesAggregateProxy(groupedByAttribute: "spec")`, so the proxy
/// this tool writes an extension on is named for the same value.
struct DiscoveredController {
    let typeName: String
    let spec: String?
    let file: String
    let line: Int
}

// MARK: - argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
guard let outputPath = arguments.first else {
    FileHandle.standardError.write(Data("WireOpenAPIGen: missing output path\n".utf8))
    exit(1)
}
arguments.removeFirst()

var imports: [String] = []
var sourcePaths: [String] = []
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--import":
        index += 1
        if index < arguments.count { imports.append(arguments[index]) }
    case "--module":
        index += 1  // the module name itself is not needed: the emitted extension is module-local
    default:
        sourcePaths.append(arguments[index])
    }
    index += 1
}

// MARK: - discovery

/// Collect every `@OpenAPIController` declaration, with the `spec:` group it names.
final class ControllerScanner: SyntaxVisitor {
    private(set) var controllers: [DiscoveredController] = []
    private let file: String
    private let converter: SourceLocationConverter

    init(file: String, tree: SourceFileSyntax) {
        self.file = file
        self.converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, attributes: node.attributes, at: node.name)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, attributes: node.attributes, at: node.name)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, attributes: node.attributes, at: node.name)
        return .visitChildren
    }

    private func record(name: String, attributes: AttributeListSyntax, at token: TokenSyntax) {
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                attribute.attributeName.trimmedDescription == "OpenAPIController"
            else { continue }
            var spec: String?
            if case .argumentList(let list) = attribute.arguments {
                for argument in list where argument.label?.text == "spec" {
                    spec = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
                }
            }
            controllers.append(
                DiscoveredController(
                    typeName: name,
                    spec: spec,
                    file: file,
                    line: converter.location(for: token.position).line
                )
            )
        }
    }
}

var discovered: [DiscoveredController] = []
for path in sourcePaths {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
    let tree = Parser.parse(source: contents)
    let scanner = ControllerScanner(file: path, tree: tree)
    scanner.walk(tree)
    discovered.append(contentsOf: scanner.controllers)
}

// MARK: - grouping

/// The proxy type swift-wire synthesises for a group — `_WireOpenAPIContributor` for the default group,
/// `_WireOpenAPIContributor_<Spec>` otherwise. Must match `aggregateProxyTypeName` in WireGenCore.
func proxyTypeName(for spec: String?) -> String {
    guard let spec, !spec.isEmpty else { return "_WireOpenAPIContributor" }
    let sanitised = String(spec.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    return "_WireOpenAPIContributor_\(sanitised)"
}

var byGroup: [String: [DiscoveredController]] = [:]
for controller in discovered {
    byGroup[controller.spec ?? "", default: []].append(controller)
}

// One conformer per spec is not a preference — `registerHandlers` is generated once per document and
// registers every operation from a single handler, so two controllers on one spec would each register the
// whole spec. Splitting a spec across controllers needs the proxy to *implement* `APIProtocol` and
// dispatch per operation, which is a later milestone; until then this is a hard error rather than silent
// double registration.
for (spec, controllers) in byGroup where controllers.count > 1 {
    let named = controllers.map(\.typeName).sorted().joined(separator: ", ")
    let label = spec.isEmpty ? "the default spec" : "spec '\(spec)'"
    let location = controllers[0]
    FileHandle.standardError.write(
        Data(
            """
            \(location.file):\(location.line): error: \(controllers.count) @OpenAPIController types share \
            \(label) (\(named)). The OpenAPI generator emits one registerHandlers per document, so each \
            would register every operation. Give them distinct `spec:` values, or wait for generated \
            per-operation dispatch.

            """.utf8
        )
    )
    exit(1)
}

// MARK: - emission

// `WireOpenAPI` and `OpenAPIRuntime` are always needed (the conformance and its `ServerTransport`
// parameter); a Wire-aware dependency may name either, so the set is deduplicated rather than appended —
// a repeated import compiles but reads like a codegen bug.
let allImports = Set(["OpenAPIRuntime", "WireOpenAPI"] + imports).sorted()
var lines: [String] = ["// Generated by WireOpenAPIGen — do not edit.", ""]
lines += allImports.map { "import \($0)" }
lines.append("")

for (spec, controllers) in byGroup.sorted(by: { $0.key < $1.key }) {
    guard !controllers.isEmpty else { continue }
    // At one subject the aggregate keeps the singular `_wireSubject` field, so the witness delegates to
    // the controller's own generated `registerHandlers`. The base path is not passed: it belongs to the
    // document's `servers:` block, which `.defaultOpenAPIServerURL` already reads.
    lines.append(
        """
        extension \(proxyTypeName(for: spec.isEmpty ? nil : spec)): TransportContributor {
            func registerWireHandlers(on transport: any ServerTransport) throws {
                try _wireSubject.registerHandlers(on: transport)
            }
        }
        """
    )
    lines.append("")
}

try (lines.joined(separator: "\n")).write(toFile: outputPath, atomically: true, encoding: .utf8)
