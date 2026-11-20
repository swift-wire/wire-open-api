// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import WireOpenAPINaming

// What the document lets a typed handler return beyond its body: a status enum of its documented
// successes, each case carrying the generated `Headers` its response declares, or — with no status to
// choose — the one success's `Headers`. Everything here is decided at build time. The generated forwarder
// checks nothing about the status or headers at run time, because the compiler holds the handler to the
// types these checks hold to the document.

extension DirectDispatchEmitter {
    /// A handler returning its status chooses among the document's successes per call, so there has to be
    /// a choice to make, nothing else on the method may make it instead, and the enum it returns has to be
    /// exactly the choice the document offers.
    func diagnoseReturnedStatus(_ operation: DiscoveredOperation, successes: [SpecResponse]) {
        let id = operation.operationID
        if let written = operation.responseStatus, let annotation = operation.statusAnnotation {
            fail(
                """
                '\(id)' returns a status enum and also names a status with \
                @\(annotation)(\(annotation == "JSONResponse" ? "status: " : "").\(written)). The two \
                contradict each other — drop the annotation, or return without the status enum.
                """,
                at: operation
            )
        }
        if operation.responseShape.headersBesideStatus {
            fail(
                """
                '\(id)' returns header fields beside its status, but an operation's headers travel in its \
                status enum: each case whose response declares headers carries them. \
                \(enumDeclaration(operation, successes)) and return \(statusReturn(operation)).
                """,
                at: operation
            )
        }
        diagnoseSuccessCount(operation, successes: successes)
        diagnoseStatusType(operation, successes: successes)
        // The handler did not pick these responses, the document offered them, and the handler has one
        // body to answer every one of them with.
        for selected in successes {
            let hasBody = !selected.contentTypes.isEmpty
            if hasBody != (operation.returnType != nil) {
                fail(
                    """
                    '\(id)' returns a status enum \(operation.returnType == nil ? "without" : "with") a \
                    body, but its documented \(selected.code) success carries \(hasBody ? "one" : "none"). \
                    Every success a status enum can answer with has to agree on whether it carries a body — \
                    document them alike, or use @RawOperation.
                    """,
                    at: operation
                )
            }
        }
    }

    /// A choice needs at least two successes, and the remedy for fewer is the form that fits the one there is.
    private func diagnoseSuccessCount(_ operation: DiscoveredOperation, successes: [SpecResponse]) {
        let id = operation.operationID
        guard successes.count < 2 else { return }
        guard let only = successes.first else {
            fail(
                """
                '\(id)' returns a status enum, but documents no success response, so there is nothing \
                to choose between. Document the successes it can answer with.
                """,
                at: operation
            )
        }
        fail(
            """
            '\(id)' returns a status enum, but documents only \
            .\(GeneratorStatusNames.safeName(for: only.code)), so there is nothing to choose between. \
            Return \(singleReturn(operation, only)), or document the other successes.
            """,
            at: operation
        )
    }

    /// The status must be an enum whose cases are exactly the operation's documented successes, named as
    /// the generated `Output` cases are, each carrying exactly its response's generated `Headers` — the
    /// only type that lets the compiler, rather than a run-time check, refuse a status or a header the
    /// document does not declare.
    ///
    /// Compared here, and only here: the forwarder's switch names each documented success and binds each
    /// payload into the generated response, so a mismatch would also fail to compile, but as an error
    /// inside generated code rather than a message about the document.
    private func diagnoseStatusType(_ operation: DiscoveredOperation, successes: [SpecResponse]) {
        guard let returned = operation.responseShape.returnedStatus else { return }
        let enumName = "\(operationNamespace(operation)).SuccessStatus"
        let declaration = "\(enumDeclaration(operation, successes)) and return \(statusReturn(operation))."
        let prefix = "'\(operation.operationID)' returns its status as"
        switch returned {
        case .httpResponseStatus(let written):
            fail(
                """
                \(prefix) '\(written)', which would let the handler answer with a status its document does \
                not declare. Return an enum of the documented successes instead. \(declaration)
                """,
                at: operation
            )
        case .unresolved(let written, .notFound):
            fail(
                """
                \(prefix) '\(written)', which names no enum declared in the sources this build reads. The \
                status has to be an enum of the documented successes. \(declaration)
                """,
                at: operation
            )
        case .unresolved(let written, .ambiguous(let count)):
            fail(
                """
                \(prefix) '\(written)', which matches \(count) enum declarations in the sources this build \
                reads. Qualify it, as `\(enumName)`, so it names one.
                """,
                at: operation
            )
        case .declared(let written, let declared):
            diagnoseStatusCases(operation, written: written, declared: declared.cases, successes: successes)
            for response in successes {
                guard let found = declared.cases.first(where: { $0.name == safeName(response) }) else { continue }
                diagnoseCasePayload(operation, written: written, found, response)
            }
        }
    }

    /// The declared case names against the documented successes, naming the difference both ways.
    private func diagnoseStatusCases(
        _ operation: DiscoveredOperation,
        written: String,
        declared: [DeclaredCase],
        successes: [SpecResponse]
    ) {
        let documented = successes.map(safeName)
        let names = declared.map(\.name)
        let listed = { (names: [String]) in names.map { ".\($0)" }.joined(separator: ", ") }
        let missing = documented.filter { !names.contains($0) }
        let extra = names.filter { !documented.contains($0) }
        guard missing.isEmpty, extra.isEmpty else {
            let parts =
                (extra.isEmpty ? [] : ["declares \(listed(extra)), which the document does not"])
                + (missing.isEmpty ? [] : ["omits \(listed(missing)), which the document declares"])
            fail(
                """
                '\(operation.operationID)' returns its status as '\(written)', whose cases must be exactly \
                the operation's documented successes (\(listed(documented))). It \
                \(parts.joined(separator: ", and ")).
                """,
                at: operation
            )
        }
    }

    /// One case's payload against its response: the response's generated `Headers` exactly when it
    /// declares headers, and nothing when it does not.
    private func diagnoseCasePayload(
        _ operation: DiscoveredOperation,
        written: String,
        _ found: DeclaredCase,
        _ response: SpecResponse
    ) {
        let subject =
            "'\(operation.operationID)' returns its status as '\(written)', whose case .\(found.name)"
        let expected = headersType(operation, response)
        let fix = "Declare it as `\(caseDeclaration(operation, response))`."
        if response.headers.isEmpty {
            guard found.payload.isEmpty else {
                fail(
                    """
                    \(subject) carries a payload, but the documented \(response.code) response declares no \
                    headers, so there is nothing for it to carry. \(fix)
                    """,
                    at: operation
                )
            }
            return
        }
        if found.payload.isEmpty {
            fail(
                """
                \(subject) carries no headers, but the documented \(response.code) response declares \
                \(listedHeaders(response)). \(fix)
                """,
                at: operation
            )
        }
        if found.payload.count != 1 || !sameType(found.payload[0], expected) {
            fail(
                """
                \(subject) carries (\(found.payload.joined(separator: ", "))), but the documented \
                \(response.code) response's headers are `\(expected)`. \(fix)
                """,
                at: operation
            )
        }
    }

    /// The headers a handler with no status to choose returns, against its one response.
    ///
    /// Returned, they must be exactly that response's generated `Headers`, which the response must have.
    /// Not returned, the response must declare no required header, since the generated response cannot be
    /// built without one.
    func diagnoseResponseHeaders(_ operation: DiscoveredOperation) {
        guard !operation.returnsStatus else { return }
        let id = operation.operationID
        let response = selectedResponse(for: operation)
        let caseName = ".\(safeName(response))"
        if let written = operation.responseShape.headersType {
            guard !response.headers.isEmpty else {
                fail(
                    """
                    '\(id)' returns headers, but its documented \(caseName) response declares none. Return \
                    \(singleReturn(operation, response)).
                    """,
                    at: operation
                )
            }
            let expected = headersType(operation, response)
            if written.split(separator: ".").last == "HTTPFields" {
                fail(
                    """
                    '\(id)' returns its headers as '\(written)', which would let the handler send headers its \
                    document does not declare. Return \(singleReturn(operation, response)) — the generated \
                    headers of its \(caseName) response.
                    """,
                    at: operation
                )
            }
            if !sameType(written, expected) {
                fail(
                    """
                    '\(id)' returns its headers as '\(written)', but its documented \(caseName) response's \
                    headers are `\(expected)`. Return \(singleReturn(operation, response)).
                    """,
                    at: operation
                )
            }
            return
        }
        if let required = response.headers.first(where: \.isRequired) {
            fail(
                """
                '\(id)' documents a \(response.code) response with the required header '\(required.name)', \
                but its handler returns no headers. Return \(singleReturn(operation, response)) and set it.
                """,
                at: operation
            )
        }
    }

    // MARK: - the types and declarations the fix-its name

    private func safeName(_ response: SpecResponse) -> String {
        GeneratorStatusNames.safeName(for: response.code)
    }

    /// The generated `Headers` of a response that declares any: under its component when it is a
    /// reference, under the operation's `Output` otherwise — where swift-openapi-generator puts it.
    func headersType(_ operation: DiscoveredOperation, _ response: SpecResponse) -> String {
        if let component = response.component {
            return
                "Components.Responses.\(GeneratorSafeNames.swiftTypeName(for: component, strategy: namingStrategy)).Headers"
        }
        let name = safeName(response)
        return "\(operationNamespace(operation)).Output.\(name.prefix(1).uppercased() + name.dropFirst()).Headers"
    }

    /// Whether a written type spells the expected one, ignoring a module qualifier in front of
    /// `Operations` or `Components`. Only the spelling is compared; the compiler checks the rest.
    private func sameType(_ written: String, _ expected: String) -> Bool {
        let components = written.filter { !$0.isWhitespace }.split(separator: ".").map(String.init)
        let start = components.firstIndex { $0 == "Operations" || $0 == "Components" } ?? 0
        return components[start...].joined(separator: ".") == expected
    }

    private func caseDeclaration(_ operation: DiscoveredOperation, _ response: SpecResponse) -> String {
        response.headers.isEmpty
            ? "case \(safeName(response))"
            : "case \(safeName(response))(\(headersType(operation, response)))"
    }

    private func enumDeclaration(_ operation: DiscoveredOperation, _ successes: [SpecResponse]) -> String {
        let cases = successes.map { caseDeclaration(operation, $0) }.joined(separator: "; ")
        return
            "Declare `extension \(operationNamespace(operation)) { enum SuccessStatus: Sendable, Hashable { \(cases) } }`"
    }

    /// The return type a status-choosing handler writes: the enum beside the body, or the enum alone.
    private func statusReturn(_ operation: DiscoveredOperation) -> String {
        let enumName = "\(operationNamespace(operation)).SuccessStatus"
        guard let body = operation.returnType else { return "`\(enumName)`" }
        return "`(status: \(enumName), body: \(body))`"
    }

    /// What a handler answering with one response returns: its headers beside the body, its headers
    /// alone, the body alone, or nothing.
    private func singleReturn(_ operation: DiscoveredOperation, _ response: SpecResponse) -> String {
        let body = operation.returnType
        guard !response.headers.isEmpty else { return body == nil ? "nothing" : "the body alone" }
        let headers = headersType(operation, response)
        guard let body else { return "`\(headers)`" }
        return "`(headers: \(headers), body: \(body))`"
    }

    private func listedHeaders(_ response: SpecResponse) -> String {
        let names = response.headers.map { "'\($0.name)'" }
        return names.count == 1 ? "the header \(names[0])" : "the headers \(names.joined(separator: ", "))"
    }
}
