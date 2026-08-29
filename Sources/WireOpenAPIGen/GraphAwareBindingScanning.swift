import SwiftParser
import SwiftSyntax

// Graph-aware request bindings, as *this* generator needs to see them.
//
// A request binding is normally a property wrapper whose static `bind` decodes a value out of the request,
// and the typed shim never calls it: `@Path`/`@Query`/`@Header` are markers naming which member of the
// generated `Input` a handler parameter reads, because the document is the authority for where a parameter
// lives.
//
// A **graph-aware** binding is not that. Its value is resolved from the request scope — a store read, a
// policy consulted — and it never crosses the wire, so the document has nothing to say about it and the
// generated `Input` has no member for it. It is bound by calling the worker the wrapper names.
//
// WireMVC's own codegen reads the same declaration for the same reason; neither generator is told about the
// other, and both reach the same answer from the attribute the author wrote. See `FactoryLiftNaming` in
// wire-mvc for the arrangement this follows.

/// The graph-aware bindings reachable in `sources`: wrapper type → the worker it names, together with the
/// seed of the scope that worker is bound in.
struct GraphAwareBindings {
    /// `@RequestBinding(Worker.self, …)` — wrapper type name → worker type name.
    private let workers: [String: String]
    /// `@Scoped(seed: X.self)` — type name → seed, for resolving a worker's scope.
    private let seeds: [String: String]

    /// The worker a parameter attribute names, or `nil` when the attribute is an ordinary binding (or none
    /// of this generator's business).
    func worker(forAttribute attribute: String) -> String? { workers[attribute] }

    /// The seed of the scope `worker` is bound in, or `nil` when its declaration is not in these sources.
    func seed(ofWorker worker: String) -> String? { seeds[worker] }

    init(sources: [(module: String, paths: [String])]) {
        var workers: [String: String] = [:]
        var seeds: [String: String] = [:]
        for group in sources {
            for path in group.paths {
                guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let scanner = GraphAwareBindingScanner(viewMode: .sourceAccurate)
                scanner.walk(Parser.parse(source: contents))
                workers.merge(scanner.workers) { existing, _ in existing }
                seeds.merge(scanner.seeds) { existing, _ in existing }
            }
        }
        self.workers = workers
        self.seeds = seeds
    }
}

private final class GraphAwareBindingScanner: SyntaxVisitor {
    var workers: [String: String] = [:]
    var seeds: [String: String] = [:]

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node.attributes)
        return .visitChildren
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node.attributes)
        return .visitChildren
    }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node.attributes)
        return .visitChildren
    }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node.attributes)
        return .visitChildren
    }

    private func record(_ name: String, _ attributes: AttributeListSyntax) {
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                case .argumentList(let arguments) = attribute.arguments
            else { continue }
            switch attribute.attributeName.trimmedDescription {
            case "RequestBinding":
                // The leading `Worker.self`. Recognised by spelling rather than position: an obligation is
                // a member reference (`.body`) and a worker is a metatype, so neither can be read as the
                // other however they are ordered.
                for argument in arguments where argument.label == nil {
                    let written = argument.expression.trimmedDescription
                    guard written.hasSuffix(".self") else { continue }
                    workers[name] = String(written.dropLast(".self".count))
                    break
                }
            case "Scoped":
                guard let seed = arguments.first(where: { $0.label?.text == "seed" }) else { continue }
                let written = seed.expression.trimmedDescription
                seeds[name] = written.hasSuffix(".self") ? String(written.dropLast(".self".count)) : written
            default:
                continue
            }
        }
    }
}

/// The scope-entry field a worker is yielded under — the same name swift-wire gives it.
///
/// swift-wire names every binding `lowerCamel(sanitize(type))`, where the sanitiser turns `<` into `Of`,
/// `,` into `And`, upper-cases the letter after either, and drops everything else. Restated here for the
/// reason wire-mvc restates it: neither side sees the other's output, so the name is computed twice from
/// one input and the two agree by running one rule.
func scopeYieldFieldName(forType type: String) -> String {
    var sanitised = ""
    var capitaliseNext = false
    for character in type {
        switch character {
        case "<":
            sanitised += "Of"
            capitaliseNext = true
        case ",":
            sanitised += "And"
            capitaliseNext = true
        case _ where character.isLetter || character.isNumber || character == "_":
            sanitised += capitaliseNext ? character.uppercased() : String(character)
            capitaliseNext = false
        default:
            break
        }
    }
    guard let first = sanitised.first else { return sanitised }
    return first.lowercased() + sanitised.dropFirst()
}
