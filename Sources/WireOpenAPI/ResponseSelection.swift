// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import HTTPTypes
public import OpenAPIRuntime

// The runtime half of a typed operation that returns a *response tuple* — `(status:body:)`,
// `(status:headers:body:)`, `(status:headers:)` or `(headers:body:)`, the shapes a WireMVC route returns
// to say something about its response alongside the body.
//
// The document decides which responses the operation may answer with; the generated forwarder switches
// over them, one generated `Output` case each. The status is not checked here: a handler returning one
// returns an enum of exactly the operation's documented successes, which the generator verifies against
// the document, so the compiler refuses any other status and the forwarder's switch over it is
// exhaustive. What cannot be decided when the code is generated is the *header fields* the handler
// returns, a run-time value. Those are checked here, on every call, against what the chosen response
// declares — and a handler that answers with something the document does not describe is the service
// breaking its own contract, which is what the error below says.

/// A typed operation answered with a response its document does not describe.
///
/// Thrown by the generated forwarder when the handler's returned header fields name one the chosen
/// response does not declare, or omit one it declares as required. A status outside the documented
/// successes is not among the reasons: the handler cannot return one.
///
/// **Always 500, never a body**, for the reason ``WireOpenAPIResponseValidationError`` is: the caller did
/// nothing wrong and can do nothing about it. It is rethrown past every `@ErrorResponse` clause in the
/// forwarder, so a catch-all written to answer bad requests cannot answer this with a client-error status.
public struct WireOpenAPIUndocumentedResponse: Error, Sendable, Equatable, HTTPResponseConvertible {
    /// What about the response the document does not describe.
    public enum Reason: Sendable, Equatable {
        /// A returned header field the chosen response does not declare, by its canonical name.
        case undeclaredHeader(String)
        /// A header the chosen response declares as required, absent from the returned fields.
        case missingHeader(String)
    }

    public let operationID: String
    /// The status of the response being built when the breach was found.
    public let status: HTTPResponse.Status
    public let reason: Reason

    public init(operationID: String, status: HTTPResponse.Status, reason: Reason) {
        self.operationID = operationID
        self.status = status
        self.reason = reason
    }

    public var httpStatus: HTTPResponse.Status { .internalServerError }
}

/// One declared header's value, read from the fields a handler returned.
///
/// `nil` for an optional header the handler did not set. A *required* one that is absent throws, since the
/// generated `Headers` member is non-optional and there is nothing honest to put in it.
///
/// The name is the document's spelling. `HTTPField.Name` compares case-insensitively, so `ETag` in the
/// document finds `etag` in the fields; a name that is not a valid field name finds nothing, which for a
/// required header is the same failure as its absence.
public func wireOpenAPIResponseHeader(
    _ name: String,
    in fields: HTTPFields,
    required: Bool,
    operationID: String,
    status: HTTPResponse.Status
) throws -> String? {
    let value = HTTPField.Name(name).flatMap { fields[$0] }
    guard value == nil, required else { return value }
    throw WireOpenAPIUndocumentedResponse(operationID: operationID, status: status, reason: .missingHeader(name))
}

/// The required form of ``wireOpenAPIResponseHeader(_:in:required:operationID:status:)``, typed
/// non-optional so the generated `Headers` member can take it directly.
public func wireOpenAPIRequiredResponseHeader(
    _ name: String,
    in fields: HTTPFields,
    operationID: String,
    status: HTTPResponse.Status
) throws -> String {
    guard
        let value = try wireOpenAPIResponseHeader(
            name,
            in: fields,
            required: true,
            operationID: operationID,
            status: status
        )
    else {
        // Unreachable: the required form throws rather than return nil. Spelled out so the signature can
        // be non-optional without a force-unwrap.
        throw WireOpenAPIUndocumentedResponse(operationID: operationID, status: status, reason: .missingHeader(name))
    }
    return value
}

/// Refuse returned header fields the chosen response does not declare.
///
/// The generated response carries its headers as typed members, one per declared header, so a field with
/// no member has nowhere to go. Dropping it silently would make a header the handler plainly meant to send
/// vanish from the wire; refusing it says, on the first request that reaches it, that the document and the
/// handler disagree.
///
/// `declared` holds the document's spellings; the comparison is case-insensitive, as field names are.
public func wireOpenAPICheckResponseHeaders(
    _ fields: HTTPFields,
    declared: Set<String>,
    operationID: String,
    status: HTTPResponse.Status
) throws {
    let known = Set(declared.map { $0.lowercased() })
    for field in fields where !known.contains(field.name.canonicalName) {
        throw WireOpenAPIUndocumentedResponse(
            operationID: operationID,
            status: status,
            reason: .undeclaredHeader(field.name.canonicalName)
        )
    }
}
