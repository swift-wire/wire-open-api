// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import WireOpenAPINaming

// The forwarder body for a typed operation that returns a status enum or its response's headers, in a
// response tuple or bare.

extension DirectDispatchEmitter {
    /// What such a handler answers with, given `wireOpenAPIResult` in hand.
    ///
    /// With a status, the handler chose at run time by returning a case of an enum of the operation's
    /// documented successes, whose cases and payloads `diagnoseReturnedStatus` verified against the
    /// document. So this switches over that enum, one generated `Output` case each, with no `default`, and
    /// hands a case's payload — the response's generated `Headers` — straight to the generated response.
    /// Without one, the response is the one ``selectedResponse(for:)`` picks, built with the returned
    /// `Headers`. Either way nothing about the response is checked at run time but its body, as for a
    /// body returned alone: the compiler already holds the handler to the rest.
    func tupleResponse(_ operation: DiscoveredOperation, indent: String) -> String {
        let bodyLocal = "wireOpenAPIResultBody"
        let tuple = operation.isResponseTuple
        let bound =
            tuple && operation.returnType != nil
            ? "\(indent)let \(bodyLocal) = wireOpenAPIResult.body\n" : ""
        guard operation.returnsStatus else {
            let headers = tuple ? "wireOpenAPIResult.headers" : "wireOpenAPIResult"
            return bound
                + constructed(
                    selectedResponse(for: operation),
                    operation,
                    headers: headers,
                    body: bodyLocal,
                    indent: indent
                )
        }
        let cases = candidateResponses(for: operation).map { response in
            let name = GeneratorStatusNames.safeName(for: response.code)
            let pattern = response.headers.isEmpty ? ".\(name)" : ".\(name)(let wireOpenAPIHeaders)"
            return "\(indent)case \(pattern):\n"
                + constructed(
                    response,
                    operation,
                    headers: response.headers.isEmpty ? nil : "wireOpenAPIHeaders",
                    body: bodyLocal,
                    indent: indent + "    "
                )
        }
        return """
            \(bound)\(indent)switch \(tuple ? "wireOpenAPIResult.status" : "wireOpenAPIResult") {
            \(cases.joined(separator: "\n"))
            \(indent)}
            """
    }

    /// One documented response, built from what the handler returned: its generated `Headers` passed as
    /// they are, its body checked and wrapped.
    private func constructed(
        _ response: SpecResponse,
        _ operation: DiscoveredOperation,
        headers: String?,
        body: String,
        indent: String
    ) -> String {
        let caseName = GeneratorStatusNames.safeName(for: response.code)
        var arguments: [String] = []
        var prelude = ""
        if let headers { arguments.append("headers: \(headers)") }
        if operation.returnType != nil {
            prelude += responseCheck(
                response.assertions,
                access: body,
                operationID: operation.operationID,
                indent: indent
            )
            arguments.append("body: .json(\(body))")
        }
        return "\(prelude)\(indent)return .\(caseName)(.init(\(arguments.joined(separator: ", "))))"
    }
}
