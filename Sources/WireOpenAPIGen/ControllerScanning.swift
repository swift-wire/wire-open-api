import Foundation
import SwiftParser
import SwiftSyntax

// Reading the consumer's controllers: which types bear `@OpenAPIController`, which spec each names, and
// which of their methods are `@RawOperation`s — with the `@Middleware` each declares, at both scopes.
//
// Everything here is syntactic. The generated types this codegen names do not exist when it runs (the
// OpenAPI generator emits them from the same build), which is exactly why the plugin reads the document
// rather than the generator's output.

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

    /// The `@ErrorResponse(E.self, .status)` pairs on a declaration, in source order.
    private func errorMappings(of attributes: AttributeListSyntax) -> [ErrorMapping] {
        var mappings: [ErrorMapping] = []
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                attribute.attributeName.trimmedDescription == "ErrorResponse",
                case .argumentList(let list) = attribute.arguments
            else { continue }
            let arguments = Array(list)
            // The three-argument form: type, status, and a closure producing the body.
            if arguments.count == 3, let closure = arguments[2].expression.as(ClosureExprSyntax.self) {
                let written = arguments[0].expression.trimmedDescription
                let status = arguments[1].expression.trimmedDescription
                mappings.append(
                    ErrorMapping(
                        errorType: written.hasSuffix(".self") ? String(written.dropLast(5)) : written,
                        status: status.hasPrefix(".") ? String(status.dropFirst()) : status,
                        bodyClosure: "(\(closure.trimmedDescription))"
                    )
                )
                continue
            }
            guard arguments.count == 2 else {
                // One argument is the closure form.
                diagnose(
                    "@ErrorResponse's closure form is not supported for OpenAPI operations yet: it "
                        + "returns a WireMVCOutcome (a status and bytes), while an operation returns the "
                        + "document's Output. Use the @ErrorResponse(E.self, .status) form.",
                    at: attribute.attributeName.firstToken(viewMode: .sourceAccurate)
                        ?? attribute.atSign
                )
            }
            let written = arguments[0].expression.trimmedDescription
            let status = arguments[1].expression.trimmedDescription
            mappings.append(
                ErrorMapping(
                    errorType: written.hasSuffix(".self") ? String(written.dropLast(5)) : written,
                    status: status.hasPrefix(".") ? String(status.dropFirst()) : status,
                    bodyClosure: nil
                )
            )
        }
        return mappings
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
            var isTyped = false
            for element in function.attributes {
                guard let attribute = element.as(AttributeSyntax.self) else { continue }
                let name = attribute.attributeName.trimmedDescription
                guard name == "RawOperation" || name == "Operation" else { continue }
                isTyped = name == "Operation"
                operationID = function.name.text
                if case .argumentList(let list) = attribute.arguments, let first = list.first {
                    operationID =
                        first.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
                        ?? function.name.text
                }
            }
            guard let operationID else { continue }
            if isTyped {
                found.append(typedOperation(operationID, function))
                continue
            }
            let parameters = function.signature.parameterClause.parameters
            guard parameters.count == 1, let parameter = parameters.first,
                let returnType = function.signature.returnClause?.type
            else {
                diagnose(
                    "@RawOperation '\(operationID)' must take the operation's generated Input and return "
                        + "its Output — that is the shape the generated operation method dispatches to.",
                    at: function.name
                )
            }
            found.append(
                DiscoveredOperation(
                    operationID: operationID,
                    middleware: middlewareArguments(of: function.attributes),
                    methodName: function.name.text,
                    inputType: parameter.type.trimmedDescription,
                    outputType: returnType.trimmedDescription,
                    parameters: [],
                    returnType: nil,
                    isTyped: false,
                    responseStatus: nil,
                    statusAnnotation: nil,
                    errorMappings: errorMappings(of: function.attributes),
                    line: converter.location(for: function.name.position).line
                )
            )
        }
        return found
    }

    /// The status named by `@JSONResponse(status: .created)`, as written — `created`. Resolving it to a
    /// code needs the document, so that happens where the document is in hand.
    private func responseStatus(of attributes: AttributeListSyntax) -> (status: String, annotation: String)? {
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                case .argumentList(let list) = attribute.arguments
            else { continue }
            let name = attribute.attributeName.trimmedDescription
            // `@JSONResponse(status:)` is labelled; `@ResponseStatus(_:)` is positional.
            let argument: LabeledExprSyntax?
            switch name {
            case "JSONResponse": argument = list.first { $0.label?.text == "status" }
            case "ResponseStatus": argument = list.first { $0.label == nil }
            default: continue
            }
            guard let argument else { continue }
            let written = argument.expression.trimmedDescription
            return (written.hasPrefix(".") ? String(written.dropFirst()) : written, name)
        }
        return nil
    }

    /// An `@Operation` method: every parameter carries a binding wrapper, and the return type is the
    /// response body the shim wraps.
    private func typedOperation(_ operationID: String, _ function: FunctionDeclSyntax) -> DiscoveredOperation {
        // No return clause is not an error: it is how a documented no-content response is written. The
        // emitter checks that against the response it selects.
        let returnType = function.signature.returnClause?.type.trimmedDescription
        var parameters: [BoundParameter] = []
        for parameter in function.signature.parameterClause.parameters {
            var binding: String?
            var documented: String?
            for element in parameter.attributes {
                guard let attribute = element.as(AttributeSyntax.self) else { continue }
                let name = attribute.attributeName.trimmedDescription
                guard ["Path", "Query", "Header", "JSONBody"].contains(name) else { continue }
                binding = name
                if case .argumentList(let list) = attribute.arguments, let first = list.first {
                    documented = first.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
                }
            }
            // The parameter's own name is `secondName` when it has both, e.g. `_ id: String`.
            let ownName = (parameter.secondName ?? parameter.firstName).text
            guard let binding else {
                diagnose(
                    "parameter '\(ownName)' of @Operation '\(operationID)' needs a binding annotation — "
                        + "one of @Path, @Query, @Header, @JSONBody. The document says where each "
                        + "parameter lives; "
                        + "the annotation says which one this is.",
                    at: parameter.firstName
                )
            }
            let label = parameter.firstName.text == "_" ? nil : parameter.firstName.text
            parameters.append(
                BoundParameter(
                    binding: binding,
                    documentedName: documented ?? ownName,
                    label: label,
                    name: ownName,
                    type: parameter.type.trimmedDescription
                )
            )
        }
        let named = responseStatus(of: function.attributes)
        return DiscoveredOperation(
            operationID: operationID,
            middleware: middlewareArguments(of: function.attributes),
            methodName: function.name.text,
            inputType: nil,
            outputType: nil,
            parameters: parameters,
            returnType: returnType,
            isTyped: true,
            responseStatus: named?.status,
            statusAnnotation: named?.annotation,
            errorMappings: errorMappings(of: function.attributes),
            line: converter.location(for: function.name.position).line
        )
    }

    /// Report and exit — a malformed `@RawOperation` cannot produce a forwarder, and continuing would
    /// emit an incomplete conformance whose error points at generated code instead of the method.
    private func diagnose(_ message: String, at token: TokenSyntax) -> Never {
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
                    errorMappings: errorMappings(of: attributes),
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
