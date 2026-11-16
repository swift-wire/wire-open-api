// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import WireOpenAPINaming

// The forwarder body for a typed operation that returns a response tuple.

extension DirectDispatchEmitter {
    /// What a handler returning a **response tuple** answers with, given `wireOpenAPIResult` in hand.
    ///
    /// Without a `status` the response is the one ``selectedResponse(for:)`` picks, as for a bare body.
    /// With one, the handler chose at run time by returning a case of an enum of the operation's
    /// documented successes — its cases verified against the document by `diagnoseReturnedStatus` — so this
    /// switches over that enum, one generated `Output` case each, with no `default`. The switch is
    /// exhaustive because the enum is closed: a status the document does not declare is not a value the
    /// handler can produce, and so not one this forwarder has to answer.
    func tupleResponse(_ operation: DiscoveredOperation, indent: String) -> String {
        let bodyLocal = "wireOpenAPIResultBody"
        let bound =
            operation.returnType == nil ? "" : "\(indent)let \(bodyLocal) = wireOpenAPIResult.body\n"
        guard operation.returnsStatus else {
            let response = selectedResponse(for: operation)
            let status = "HTTPResponse.Status(code: \(response.code))"
            return bound + constructed(response, operation, status: status, body: bodyLocal, indent: indent)
        }
        let cases = candidateResponses(for: operation).map { response in
            "\(indent)case .\(GeneratorStatusNames.safeName(for: response.code)):\n"
                + constructed(
                    response,
                    operation,
                    status: "HTTPResponse.Status(code: \(response.code))",
                    body: bodyLocal,
                    indent: indent + "    "
                )
        }
        return """
            \(bound)\(indent)switch wireOpenAPIResult.status {
            \(cases.joined(separator: "\n"))
            \(indent)}
            """
    }

    /// One documented response, built from a response tuple: its declared headers read out of the returned
    /// fields, its body checked and wrapped.
    ///
    /// The generated `Headers` initialiser takes one argument per declared header, in document order —
    /// the order `SpecResponse.headers` keeps — named by the same safe-name transform as every other
    /// member. A required header the fields omit, and a field the response does not declare, both throw
    /// `WireOpenAPIUndocumentedResponse`: the generated type has no member for the one and nothing honest
    /// to put in the other.
    private func constructed(
        _ response: SpecResponse,
        _ operation: DiscoveredOperation,
        status: String,
        body: String,
        indent: String
    ) -> String {
        let caseName = GeneratorStatusNames.safeName(for: response.code)
        let id = operation.operationID
        var arguments: [String] = []
        var prelude = ""
        if operation.returnsHeaders {
            let declared = response.headers.map { "\"\($0.name)\"" }.joined(separator: ", ")
            prelude += """
                \(indent)try wireOpenAPICheckResponseHeaders(
                \(indent)    wireOpenAPIResult.headers,
                \(indent)    declared: [\(declared)],
                \(indent)    operationID: "\(id)",
                \(indent)    status: \(status)
                \(indent))

                """
            if !response.headers.isEmpty {
                let members = response.headers.map { header -> String in
                    let member = GeneratorSafeNames.swiftMemberName(for: header.name, strategy: namingStrategy)
                    let read =
                        header.isRequired
                        ? "try wireOpenAPIRequiredResponseHeader(\"\(header.name)\", in: wireOpenAPIResult.headers, "
                            + "operationID: \"\(id)\", status: \(status))"
                        : "try wireOpenAPIResponseHeader(\"\(header.name)\", in: wireOpenAPIResult.headers, "
                            + "required: false, operationID: \"\(id)\", status: \(status))"
                    return "\(member): \(read)"
                }
                arguments.append("headers: .init(\(members.joined(separator: ", ")))")
            }
        }
        if operation.returnType != nil {
            prelude += responseCheck(response.assertions, access: body, operationID: id, indent: indent)
            arguments.append("body: .json(\(body))")
        }
        return "\(prelude)\(indent)return .\(caseName)(.init(\(arguments.joined(separator: ", "))))"
    }
}
