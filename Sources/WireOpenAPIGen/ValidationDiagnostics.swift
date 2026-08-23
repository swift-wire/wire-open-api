import Foundation
import WireOpenAPINaming

// Refusing what the emitter cannot express.
//
// Split from ValidationEmission so that emitting and refusing are read separately: they walk the same
// model but answer different questions, and one file doing both had grown past the point where either
// was easy to follow.

extension DirectDispatchEmitter {
    /// An assertion this adapter cannot check is a build error, not a silent omission.
    ///
    /// The rule is the one `diagnoseMappingForm` already applies to responses: where the document asks for
    /// something the adapter cannot construct, say so rather than quietly doing nothing. A document that
    /// declares `minLength` and gets no enforcement is the exact failure this capability exists to remove,
    /// so producing it *silently* would be worse than the gap it replaces.
    ///
    /// **Keyed on request-reachability, not on the schema.** A `Components.Schemas.Task` is routinely both
    /// a request body and a response body, and response validation is not switched on — so failing a build
    /// over a constraint reachable only from a response would fail it for a feature nobody enabled. The
    /// walk therefore starts at each operation's *request* surface. Turning response validation on later
    /// widens the walk, and may legitimately turn a passing build into a failing one.
    func diagnoseParameterAssertions() {
        for (_, entry) in byOperationID.sorted(by: { $0.key < $1.key }) {
            var visited: Set<String> = []
            for root in requestRoots(for: entry.operation) {
                diagnose(
                    root.node,
                    at: "the request of",
                    subject: root.path,
                    of: entry.operation,
                    visited: &visited
                )
            }
            // Responses only when the document's `wire-openapi.yaml` asks for them to be checked.
            // `responseRoots` is empty otherwise, which is the whole of the request-reachability rule:
            // a constraint reachable only from a response must not fail a build for a check nobody
            // switched on. Turning it on widens this walk, and may legitimately turn a passing build
            // into a failing one.
            for root in responseRoots(for: entry.operation) {
                diagnose(
                    root.node,
                    at: "the \(root.code) response of",
                    subject: "body",
                    of: entry.operation,
                    visited: &visited
                )
            }
        }
    }

    private func diagnose(
        _ node: SpecAssertions,
        at side: String,
        subject path: String,
        of operation: DiscoveredOperation,
        visited: inout Set<String>
    ) {
        switch node {
        case .none, .integer, .number:
            return
        case .array(_, _, _, let items):
            diagnose(items, at: side, subject: "\(path)[]", of: operation, visited: &visited)
        case .object(let properties):
            for property in properties {
                diagnose(
                    property.assertions,
                    at: side,
                    subject: "\(path).\(property.name)",
                    of: operation,
                    visited: &visited
                )
            }
        case .composed(let members):
            // Reported at the parent's path, because that is where the caller would see it — `value1` has
            // no wire counterpart.
            for member in members {
                diagnose(member.assertions, at: side, subject: path, of: operation, visited: &visited)
            }
        case .reference(let name):
            // Once per schema per operation: a schema reached from three properties has one problem, not
            // three, and a recursive one would otherwise not terminate.
            guard visited.insert(name).inserted else { return }
            componentSchemas[name].map {
                diagnose($0, at: side, subject: path, of: operation, visited: &visited)
            }
        case .unrepresentable(let keywords, let reason):
            fail(
                """
                '\(path)' in \(side) '\(operation.operationID)' declares \
                \(keywords.joined(separator: ", ")), which this adapter cannot check \
                because \(reason). Remove it from the document, or check it in the handler. @RawOperation is \
                not an escape — validation is emitted for those too, from the same document.
                """,
                at: operation
            )
        case .string(_, _, let pattern):
            guard let pattern else { return }
            // Compiled with the same engine the runtime will use, so agreement is by construction rather
            // than by hope — and an unreadable expression fails the build here instead of trapping in
            // `WireOpenAPIPattern.init` on the first request that reaches it.
            guard (try? Regex(pattern)) == nil else { return }
            fail(
                """
                '\(path)' in \(side) '\(operation.operationID)' declares \
                `pattern: \(pattern)`, which Swift's regular-expression engine cannot compile. JSON Schema \
                patterns are ECMA-262; most translate directly, but this one does not. Rewrite it, or \
                remove it and check it in the handler.
                """,
                at: operation
            )
        }
    }
}
