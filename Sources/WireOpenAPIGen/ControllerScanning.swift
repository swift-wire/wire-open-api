import Foundation
import SwiftParser
import SwiftSyntax

// Reading the consumer's controllers: which types bear `@OpenAPIController`, which spec each names, and
// which of their methods are `@RawOperation`s — with the `@Middleware` each declares, at both scopes.
//
// Everything here is syntactic. The generated types this codegen names do not exist when it runs (the
// OpenAPI generator emits them from the same build), which is exactly why the plugin reads the document
// rather than the generator's output.

/// The group matches swift-wire's `.contributesAggregateProxy(groupedByAttribute: "spec")`, so the proxy
/// this tool writes an extension on is named for the same value.
/// One `@RawOperation` method: which operation it implements, and the route-scope `@Middleware` it
/// declares. Route middleware folds inside the controller's, so the two are kept separate.
struct DiscoveredOperation {
    let operationID: String
    let middleware: [String]
    /// The method's own name, and its input and output types **exactly as written**.
    ///
    /// Copying the spellings verbatim is what keeps the forwarding conformance free of the generator's
    /// safe-name transform: the forwarder is declared with the same types the user already wrote, so the
    /// codegen never has to derive `Operations.GetTask.Input` from the operationId `getTask` — a
    /// derivation that is identity for some specs and not others.
    let methodName: String
    let inputType: String
    let outputType: String
}

struct DiscoveredController {
    let typeName: String
    let spec: String?
    /// The verbatim argument of each type-level `@Middleware`, in source order — controller-scope
    /// middleware, folded around every one of this controller's operations.
    let middleware: [String]
    /// The controller's `@RawOperation` methods, in source order.
    let operations: [DiscoveredOperation]
    /// The `@Scoped(seed:)` seed type, if the controller is request-scoped — in which case the aggregate
    /// bridges into its scope per request instead of holding it.
    let seed: String?
    let file: String
    let line: Int
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
        record(name: node.name.text, attributes: node.attributes, members: node.memberBlock, at: node.name)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, attributes: node.attributes, members: node.memberBlock, at: node.name)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, attributes: node.attributes, members: node.memberBlock, at: node.name)
        return .visitChildren
    }

    /// The argument of each `@Middleware` on a declaration, in source order. Wire has already lifted the
    /// matching value onto the aggregate proxy — a method-level `@Middleware` hoists to its enclosing type
    /// (BindingDiscovery), and the proxy synthesis reattributes each subject's input edges onto the
    /// aggregate — so this only has to name the field the fold reads.
    /// The `@Scoped(seed: X.self)` seed, or `nil` for an app-scoped controller.
    private func seedType(of attributes: AttributeListSyntax) -> String? {
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                attribute.attributeName.trimmedDescription == "Scoped",
                case .argumentList(let list) = attribute.arguments
            else { continue }
            for argument in list where argument.label?.text == "seed" {
                let expression = argument.expression.trimmedDescription
                return expression.hasSuffix(".self") ? String(expression.dropLast(5)) : expression
            }
        }
        return nil
    }

    private func middlewareArguments(of attributes: AttributeListSyntax) -> [String] {
        var arguments: [String] = []
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                attribute.attributeName.trimmedDescription == "Middleware",
                case .argumentList(let list) = attribute.arguments,
                let first = list.first
            else { continue }
            arguments.append(first.expression.trimmedDescription)
        }
        return arguments
    }

    /// The `@RawOperation` methods of a controller. Bare, the method's own name is the operationId;
    /// `@RawOperation("get-task")` overrides it for a renamed method.
    private func operations(in members: MemberBlockSyntax) -> [DiscoveredOperation] {
        var found: [DiscoveredOperation] = []
        for member in members.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            var operationID: String?
            for element in function.attributes {
                guard let attribute = element.as(AttributeSyntax.self),
                    attribute.attributeName.trimmedDescription == "RawOperation"
                else { continue }
                operationID = function.name.text
                if case .argumentList(let list) = attribute.arguments, let first = list.first {
                    operationID =
                        first.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
                        ?? function.name.text
                }
            }
            guard let operationID else { continue }
            let parameters = function.signature.parameterClause.parameters
            guard parameters.count == 1, let parameter = parameters.first,
                let returnType = function.signature.returnClause?.type
            else {
                diagnose(
                    "@RawOperation '\(operationID)' must take the operation's generated Input and return "
                        + "its Output — that is the shape `registerHandlers` dispatches to.",
                    at: function.name
                )
                continue
            }
            found.append(
                DiscoveredOperation(
                    operationID: operationID,
                    middleware: middlewareArguments(of: function.attributes),
                    methodName: function.name.text,
                    inputType: parameter.type.trimmedDescription,
                    outputType: returnType.trimmedDescription
                )
            )
        }
        return found
    }

    /// Report and exit — a malformed `@RawOperation` cannot produce a forwarder, and continuing would
    /// emit an incomplete conformance whose error points at generated code instead of the method.
    private func diagnose(_ message: String, at token: TokenSyntax) -> Void {
        let line = converter.location(for: token.position).line
        FileHandle.standardError.write(Data("\(file):\(line): error: \(message)\n".utf8))
        exit(1)
    }

    private func record(
        name: String,
        attributes: AttributeListSyntax,
        members: MemberBlockSyntax,
        at token: TokenSyntax
    ) {
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
                    middleware: middlewareArguments(of: attributes),
                    operations: operations(in: members),
                    seed: seedType(of: attributes),
                    file: file,
                    line: converter.location(for: token.position).line
                )
            )
        }
    }
}

/// Every `@OpenAPIController` across the sources the plugin passed.
func discoverControllers(in sourcePaths: [String]) -> [DiscoveredController] {
    var discovered: [DiscoveredController] = []
    for path in sourcePaths {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        let tree = Parser.parse(source: contents)
        let scanner = ControllerScanner(file: path, tree: tree)
        scanner.walk(tree)
        discovered.append(contentsOf: scanner.controllers)
    }
    return discovered
}
