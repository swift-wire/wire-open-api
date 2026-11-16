// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import WireOpenAPINaming

// The build-time half of a typed operation returning a response tuple: what the document lets it answer
// with, and what it has to supply. The run-time half — the value the handler returned — is checked by
// the generated forwarder on every call.

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
