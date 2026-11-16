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
    /// What the tuple's `status` element names, or nil when it has none.
    var returnedStatus: ReturnedStatus?
    var headers = false

    /// The tuple carries a `status`.
    var status: Bool { returnedStatus != nil }

    /// `refuse` reports a labelled tuple that names response labels but is not one of the legal shapes —
    /// the scanner's own diagnostic, so the message points at the method.
    static func read(
        _ type: TypeSyntax?,
        operationID: String,
        enums: DeclaredEnums,
        refuse: (String) -> Never
    ) -> ResponseShape {
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
        let status = tuple.elements.first { $0.firstName?.text == "status" }?.type.trimmedDescription
        return ResponseShape(
            body: tuple.elements.first { $0.firstName?.text == "body" }?.type.trimmedDescription,
            isTuple: true,
            returnedStatus: status.map { ReturnedStatus($0, enums: enums) },
            headers: labels.contains("headers")
        )
    }
}

/// What a response tuple's `status` element names.
///
/// An enum of the operation's documented successes is the only legal answer, because it is the one the
/// compiler can hold the handler to. `HTTPResponse.Status` is singled out because it is the type a
/// WireMVC route's tuple uses, so it is the mistake most worth a message of its own: it would let the
/// handler return any status at all.
enum ReturnedStatus {
    case httpResponseStatus(written: String)
    case declared(written: String, DeclaredEnum)
    case unresolved(written: String, StatusEnumRefusal)

    init(_ written: String, enums: DeclaredEnums) {
        if written.split(separator: ".").suffix(2) == ["HTTPResponse", "Status"] {
            self = .httpResponseStatus(written: written)
            return
        }
        switch enums.resolve(written) {
        case .success(let declared): self = .declared(written: written, declared)
        case .failure(let refusal): self = .unresolved(written: written, refusal)
        }
    }
}

extension ControllerScanner {
    /// The response shape a typed operation's return clause declares, its status resolved against the
    /// enums this run reads.
    func responseShape(of function: FunctionDeclSyntax, operationID: String) -> ResponseShape {
        ResponseShape.read(
            function.signature.returnClause?.type,
            operationID: operationID,
            enums: indexes.declaredEnums
        ) { diagnose($0, at: function.name) }
    }
}
