// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import WireOpenAPINaming

// The build-time half of a typed operation returning a response tuple: what the document lets it answer
// with, what it has to supply, and the status enum it chooses with. The run-time half — the header fields
// the handler returned — is checked by the generated forwarder on every call.

extension DirectDispatchEmitter {
    /// A handler returning its status chooses among the document's successes per call, so there has to be
    /// a choice to make, and nothing else on the method may make it instead.
    func diagnoseReturnedStatus(_ operation: DiscoveredOperation, successes: [SpecResponse]) {
        if let written = operation.responseStatus, let annotation = operation.statusAnnotation {
            fail(
                """
                '\(operation.operationID)' returns its status in a response tuple and also names one with \
                @\(annotation)(\(annotation == "JSONResponse" ? "status: " : "").\(written)). The two \
                contradict each other — drop the annotation, or return the body alone.
                """,
                at: operation
            )
        }
        guard successes.count >= 2 else {
            let declared = successes.map { ".\(GeneratorStatusNames.safeName(for: $0.code))" }
            fail(
                """
                '\(operation.operationID)' returns its status in a response tuple, but documents \
                \(declared.first.map { "only \($0)" } ?? "no success response"), so there is nothing to \
                choose between. Return \(operation.returnsHeaders ? "(headers:body:)" : "the body alone"), \
                or document the other successes.
                """,
                at: operation
            )
        }
        diagnoseStatusType(operation, successes: successes)
        // Said in terms of the tuple: the handler did not pick these responses, the document offered them,
        // and a tuple has one `body` element to answer every one of them with.
        for selected in successes {
            let hasBody = !selected.contentTypes.isEmpty
            if hasBody != (operation.returnType != nil) {
                fail(
                    """
                    '\(operation.operationID)' returns its status in a response tuple \
                    \(operation.returnType == nil ? "without" : "with") a body, but its documented \
                    \(selected.code) success carries \(hasBody ? "one" : "none"). Every success a response tuple \
                    can answer with has to agree on whether it carries a body — document them alike, or use \
                    @RawOperation.
                    """,
                    at: operation
                )
            }
        }
    }

    /// The tuple's `status` must be an enum whose cases are exactly the operation's documented successes,
    /// named as the generated `Output` cases are — the only type that lets the compiler, rather than a
    /// run-time check, refuse a status the document does not declare.
    ///
    /// The cases are compared here, and only here: the forwarder's switch names each documented success,
    /// so a case it does not name would also fail to compile, but as an exhaustiveness error inside
    /// generated code rather than a message about the document.
    private func diagnoseStatusType(_ operation: DiscoveredOperation, successes: [SpecResponse]) {
        guard let returned = operation.responseShape.returnedStatus else { return }
        let documented = successes.map { GeneratorStatusNames.safeName(for: $0.code) }
        let enumName = "\(operationNamespace(operation)).SuccessStatus"
        let declaration = """
            Declare `extension \(operationNamespace(operation)) { enum SuccessStatus: Sendable, Hashable, \
            CaseIterable { \(documented.map { "case \($0)" }.joined(separator: "; ")) } }` and return \
            `status: \(enumName)`.
            """
        let prefix = "'\(operation.operationID)' returns its status in a response tuple"
        switch returned {
        case .httpResponseStatus(let written):
            fail(
                """
                \(prefix) as '\(written)', which would let the handler answer with a status its document \
                does not declare. Return an enum of the documented successes instead. \(declaration)
                """,
                at: operation
            )
        case .unresolved(let written, .notFound):
            fail(
                """
                \(prefix) as '\(written)', which names no enum declared in the sources this build reads. \
                The status has to be an enum of the documented successes. \(declaration)
                """,
                at: operation
            )
        case .unresolved(let written, .ambiguous(let count)):
            fail(
                """
                \(prefix) as '\(written)', which matches \(count) enum declarations in the sources this \
                build reads. Qualify it, as `\(enumName)`, so it names one.
                """,
                at: operation
            )
        case .declared(let written, let declared):
            if declared.hasAssociatedValues {
                fail(
                    """
                    \(prefix) as '\(written)', whose cases carry associated values the generated response \
                    has nowhere to put. Its cases must be plain: \(documented.joined(separator: ", ")).
                    """,
                    at: operation
                )
            }
            diagnoseStatusCases(operation, written: written, declared: declared.cases, documented: documented)
        }
    }

    /// The declared cases against the documented successes, naming the difference both ways.
    private func diagnoseStatusCases(
        _ operation: DiscoveredOperation,
        written: String,
        declared: [String],
        documented: [String]
    ) {
        let listed = { (names: [String]) in names.map { ".\($0)" }.joined(separator: ", ") }
        let missing = documented.filter { !declared.contains($0) }
        let extra = declared.filter { !documented.contains($0) }
        guard missing.isEmpty, extra.isEmpty else {
            let parts =
                (extra.isEmpty ? [] : ["declares \(listed(extra)), which the document does not"])
                + (missing.isEmpty ? [] : ["omits \(listed(missing)), which the document declares"])
            fail(
                """
                '\(operation.operationID)' returns its status in a response tuple as '\(written)', whose cases \
                must be exactly the operation's documented successes (\(listed(documented))). It \
                \(parts.joined(separator: ", and ")).
                """,
                at: operation
            )
        }
    }

    /// The headers each response the handler can construct declares, against whether it returns any.
    ///
    /// Both directions are decidable here, because the declared set is the document's. What is *not* is
    /// the returned fields' contents, which are a run-time value — those are checked on every call by
    /// `wireOpenAPICheckResponseHeaders`, and a field outside the declared set answers 500.
    func diagnoseResponseHeaders(_ operation: DiscoveredOperation) {
        for response in candidateResponses(for: operation) {
            if operation.returnsHeaders,
                let unbuildable = response.headers.first(where: { !$0.isPlainString })
            {
                fail(
                    """
                    '\(operation.operationID)' returns header fields, but its \(response.code) response \
                    declares '\(unbuildable.name)' with a schema other than a plain string, which the typed \
                    shim cannot build from a field value. Use @RawOperation for this operation.
                    """,
                    at: operation
                )
            }
            if !operation.returnsHeaders, let required = response.headers.first(where: \.isRequired) {
                let shape =
                    operation.returnsStatus
                    ? "(status:headers:\(operation.returnType == nil ? "" : "body:"))"
                    : "(headers:body:)"
                fail(
                    """
                    '\(operation.operationID)' documents a \(response.code) response with the required \
                    header '\(required.name)', but its handler returns no header fields. Return \(shape) \
                    and set it.
                    """,
                    at: operation
                )
            }
        }
    }
}
