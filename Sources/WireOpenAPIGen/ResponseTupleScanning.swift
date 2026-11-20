// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax

/// What a typed handler's return type says about its response.
///
/// A **response tuple** is WireMVC's labelled tuple, narrowed to what the document lets the compiler
/// check: `(status:body:)`, whose `status` is an enum of the documented successes carrying each one's
/// generated `Headers`, and `(headers:body:)`, whose `headers` is the one success's generated `Headers`.
/// Read by **label**, as WireMVC reads it, never by element type.
///
/// Swift has no one-element labelled tuple, so the bodiless forms are bare returns: the status enum
/// itself, recognised because it names an enum declared in the sources this run reads, or a generated
/// `Headers` type, recognised by its spelling. Anything else bare is the body type, which is what every
/// typed handler returned before tuples.
struct ResponseShape {
    /// The body's type as written, or nil when the handler returns no body.
    var body: String?
    var isTuple = false
    /// What the returned status names, or nil when the handler returns none.
    var returnedStatus: ReturnedStatus?
    /// The returned headers' type as written, for a handler with no status to choose.
    var headersType: String?
    /// A `headers` element beside a `status` — WireMVC's `(status:headers:body:)` or `(status:headers:)`,
    /// which an operation does not take: its headers travel in the status enum's cases. Kept so the
    /// refusal can name the cases to declare, which needs the document.
    var headersBesideStatus = false

    /// The handler returns a status.
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
        else { return bare(type.trimmedDescription, enums: enums) }
        let labels = tuple.elements.map { $0.firstName?.text ?? "_" }
        let legal = [["status", "body"], ["headers", "body"]]
        let besideStatus = [["status", "headers", "body"], ["status", "headers"]]
        guard legal.contains(labels) || besideStatus.contains(labels) else {
            refuse(
                "the response tuple returned by @Operation '\(operationID)' is labelled "
                    + "(\(labels.map { "\($0):" }.joined())), which is not a response shape — write "
                    + "(status:body:) or (headers:body:)."
            )
        }
        let element = { (label: String) in
            tuple.elements.first { $0.firstName?.text == label }?.type.trimmedDescription
        }
        let status = element("status")
        return ResponseShape(
            body: element("body"),
            isTuple: true,
            returnedStatus: status.map { ReturnedStatus($0, enums: enums) },
            headersType: status == nil ? element("headers") : nil,
            headersBesideStatus: status != nil && labels.contains("headers")
        )
    }

    /// A return that is not a tuple: a status enum or a generated `Headers` for a bodiless response, or
    /// otherwise the body.
    private static func bare(_ written: String, enums: DeclaredEnums) -> ResponseShape {
        let status = ReturnedStatus(written, enums: enums)
        if case .unresolved(_, .notFound) = status {
            return isGeneratedHeaders(written) ? ResponseShape(headersType: written) : ResponseShape(body: written)
        }
        return ResponseShape(returnedStatus: status)
    }

    /// `Operations.<Op>.Output.<Response>.Headers` or `Components.Responses.<Name>.Headers`, optionally
    /// module-qualified — the two places swift-openapi-generator puts a response's headers.
    static func isGeneratedHeaders(_ written: String) -> Bool {
        let components = written.split(separator: ".").map(String.init)
        guard components.last == "Headers" else { return false }
        let path = components.dropLast()
        let underOperation = path.contains("Operations") && path.contains("Output")
        return underOperation || zip(path, path.dropFirst()).contains { $0 == ("Components", "Responses") }
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
