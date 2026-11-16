// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftParser
import SwiftSyntax

// The enums a typed operation's response tuple may name as its `status`.
//
// A handler choosing its success at run time returns an enum of the operation's documented successes,
// declared by its author beside it. The *compiler* then holds the handler to that enum's cases, and this
// generator holds the cases to the document: they must be exactly the operation's 2xx responses, named
// as the generated `Output` cases are. Between the two, a status the document does not declare cannot be
// returned at all.
//
// The author declares it, rather than this generator emitting it, because this generator writes into one
// module only — the one it runs for — and a controller is routinely declared in another: a library the
// app depends on, which is how a document and its controllers ship together. A type emitted here would
// be invisible to every handler there. The declaration is read from the same sources the controllers are,
// so wherever a handler can be scanned, its enum can be.

/// One enum declaration, by the path it is nested under.
struct DeclaredEnum {
    /// The case names, in declaration order.
    let cases: [String]
    /// Whether any case carries an associated value — a payload the forwarder has nowhere to send.
    let hasAssociatedValues: Bool
}

/// Every enum in the sources this run reads, keyed by its nesting path without the module —
/// `RegistrationController.Outcome`, or `Outcome` at file scope.
struct DeclaredEnums {
    private let byPath: [String: [DeclaredEnum]]
    private let modules: Set<String>

    init(sources: [(module: String, paths: [String])]) {
        var byPath: [String: [DeclaredEnum]] = [:]
        for group in sources {
            for path in group.paths {
                guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let scanner = EnumScanner(viewMode: .sourceAccurate)
                scanner.walk(Parser.parse(source: contents))
                for (key, found) in scanner.found { byPath[key, default: []].append(contentsOf: found) }
            }
        }
        self.byPath = byPath
        self.modules = Set(sources.map(\.module))
    }

    /// The enum a written type names, or why there is not exactly one.
    ///
    /// A leading module qualifier is dropped when it names a module of this run. Otherwise the written
    /// path is matched against the *end* of each declaration's nesting path, so `Outcome` finds a
    /// nested `RegistrationController.Outcome` when it is the only `Outcome` there is — which is how Swift
    /// resolves the bare name from inside the controller.
    func resolve(_ written: String) -> Result<DeclaredEnum, StatusEnumRefusal> {
        var components = written.split(separator: ".").map(String.init)
        if components.count > 1, let first = components.first, modules.contains(first) {
            components.removeFirst()
        }
        let suffix = components.joined(separator: ".")
        let matches = byPath.filter { key, _ in key == suffix || key.hasSuffix("." + suffix) }
            .flatMap(\.value)
        guard matches.count == 1, let match = matches.first else {
            return .failure(matches.isEmpty ? .notFound : .ambiguous(count: matches.count))
        }
        return .success(match)
    }
}

/// Why a written status type does not name exactly one enum.
enum StatusEnumRefusal: Error {
    case notFound
    case ambiguous(count: Int)
}

private final class EnumScanner: SyntaxVisitor {
    var found: [String: [DeclaredEnum]] = [:]
    private var path: [String] = []

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text) }
    override func visitPost(_ node: StructDeclSyntax) { path.removeLast() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text) }
    override func visitPost(_ node: ClassDeclSyntax) { path.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text) }
    override func visitPost(_ node: ActorDeclSyntax) { path.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.extendedType.trimmedDescription)
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { path.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let elements = node.memberBlock.members
            .compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }
            .flatMap(\.elements)
        let key = (path + [node.name.text]).joined(separator: ".")
        found[key, default: []].append(
            DeclaredEnum(
                cases: elements.map(\.name.text),
                hasAssociatedValues: elements.contains { $0.parameterClause != nil }
            )
        )
        return push(node.name.text)
    }
    override func visitPost(_ node: EnumDeclSyntax) { path.removeLast() }

    private func push(_ name: String) -> SyntaxVisitorContinueKind {
        path.append(name)
        return .visitChildren
    }
}
