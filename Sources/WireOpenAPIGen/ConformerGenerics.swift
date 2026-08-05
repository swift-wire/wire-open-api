import SwiftSyntax

// The generic vocabulary the conformer needs.
//
// A controller is routinely generic: `some TodoRepository` cannot be a stored property, so a backend
// arrives as a lifted parameter that swift-wire concretizes when it builds the graph. The conformer
// *holds* its controllers, so it has to be generic in step — and it has to be so without knowing the
// names swift-wire chose for the aggregate proxy's own parameters.

/// One generic parameter of a controller: its name, and the constraint written on it.
///
/// A controller is routinely generic — `some TodoRepository` cannot be a stored property, so a backend
/// arrives as a lifted parameter that swift-wire concretizes when it builds the graph. The conformer has
/// to be generic in step, because it *holds* the controller.
struct GenericParameter {
    let name: String
    let inheritedType: String?

    init(_ syntax: GenericParameterSyntax) {
        name = syntax.name.text
        inheritedType = syntax.inheritedType?.trimmedDescription
    }

    /// As written in a parameter clause — `Repository: TodoRepository`.
    var declaration: String { inheritedType.map { "\(name): \($0)" } ?? name }
}

extension DiscoveredController {
    /// The prefix a controller's generic parameters take inside the conformer, unique per controller so
    /// two controllers each declaring `Store` do not collide. `_wire` keeps it out of the user's namespace.
    static func genericPrefix(_ index: Int) -> String { "_wireC\(index)" }
}

/// A declaration's generic syntax, as the scanner hands it to the model — one value rather than two
/// parameters, so `record` stays readable.
struct DeclGenerics {
    let parameters: [GenericParameter]
    let whereClause: String?

    init(_ clause: GenericParameterClauseSyntax?, _ whereClause: GenericWhereClauseSyntax?) {
        parameters = clause?.parameters.map { GenericParameter($0) } ?? []
        self.whereClause = whereClause?.trimmedDescription
    }
}

extension DirectDispatchEmitter {
    /// The conformer's own generic clause: every controller's parameters, each renamed by its
    /// per-controller prefix so two controllers declaring the same name do not collide.
    var conformerGenericClause: String {
        let parameters = controllers.enumerated()
            .flatMap { index, controller in
                controller.genericDeclarations(prefix: DiscoveredController.genericPrefix(index))
            }
        return parameters.isEmpty ? "" : "<\(parameters.joined(separator: ", "))>"
    }

    /// A `where` clause names the controller's *written* parameter names, which do not exist inside the
    /// conformer. Rewriting one would mean substituting into arbitrary constraint syntax by string edit,
    /// which is not something to get subtly wrong silently — so the case is refused with the fix stated.
    func rejectGenericWhereClauses() {
        for controller in controllers where controller.genericWhereClause != nil {
            fail(
                "'\(controller.typeName)' has a generic `where` clause, which the emitted conformer cannot "
                    + "reproduce: it renames the controller's generic parameters, and rewriting a clause "
                    + "that names them would mean editing constraint syntax by substitution. Write the "
                    + "constraint on the parameter itself instead — `<Store: TaskStoring>`.",
                in: controller
            )
        }
    }

    /// Emitted only when some controller is both generic and request-scoped — the one case whose template
    /// field cannot infer its own type, because the proxy holds a scope-entry thunk rather than a subject.
    /// Omitted otherwise, so the common output stays plain.
    var noSubjectHelper: String {
        guard controllers.contains(where: { $0.seed != nil && !$0.genericParameters.isEmpty }) else { return "" }
        return """

            /// A typed `nil` for a request-scoped controller's template field, with the subject type
            /// recovered from its scope-entry thunk. The thunk is never called — only its return type is
            /// read, which is what lets the template name a type this file never spells.
            static func noSubject<Seed, Subject, Teardown>(
                _ thunk: @Sendable (Seed) async throws -> (Subject, Teardown)
            ) -> Subject? { nil }

            """
    }
}
