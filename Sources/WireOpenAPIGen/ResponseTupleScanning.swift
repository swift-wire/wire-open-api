// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax

/// What a typed handler's return type says about its response.
///
/// A **response tuple** is WireMVC's: a labelled tuple naming what the handler says about the response
/// alongside its body — `(status:body:)`, `(status:headers:body:)`, `(status:headers:)` or
/// `(headers:body:)`, in that canonical order. Read by **label**, as WireMVC reads it, never by element
/// type: a syntactic scan can only compare spellings, and a body type that happens to be spelled
/// `HTTPFields` must not be mistaken for headers.
///
/// Anything else is the body type itself, which is what every typed handler returned before tuples.
struct ResponseShape {
    /// The body's type as written, or nil when the handler returns no body.
    var body: String?
    var isTuple = false
    var status = false
    var headers = false

    /// `refuse` reports a labelled tuple that names response labels but is not one of the legal shapes —
    /// the scanner's own diagnostic, so the message points at the method.
    static func read(_ type: TypeSyntax?, operationID: String, refuse: (String) -> Never) -> ResponseShape {
        guard let type else { return ResponseShape() }
        let known = ["status", "headers", "body"]
        guard let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count > 1,
            tuple.elements.contains(where: { $0.firstName.map { known.contains($0.text) } ?? false })
        else { return ResponseShape(body: type.trimmedDescription) }
        let labels = tuple.elements.map { $0.firstName?.text ?? "_" }
        let legal = [["status", "body"], ["status", "headers", "body"], ["status", "headers"], ["headers", "body"]]
        guard legal.contains(labels) else {
            refuse(
                "the response tuple returned by @Operation '\(operationID)' is labelled "
                    + "(\(labels.map { "\($0):" }.joined())), which is not a response shape — write one of "
                    + "(status:body:), (status:headers:body:), (status:headers:) or (headers:body:)."
            )
        }
        return ResponseShape(
            body: tuple.elements.first { $0.firstName?.text == "body" }?.type.trimmedDescription,
            isTuple: true,
            status: labels.contains("status"),
            headers: labels.contains("headers")
        )
    }
}
