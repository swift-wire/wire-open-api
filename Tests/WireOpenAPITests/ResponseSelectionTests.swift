// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import HTTPTypes
// `MemberImportVisibility`: `ServerError` and `httpStatus`'s protocol are the OpenAPI runtime's.
import OpenAPIRuntime
import Testing

@testable import WireOpenAPI

/// The run-time checks a typed operation returning a response tuple makes on every call.
///
/// The document fixes which responses the operation may answer with, and the generator switches over
/// them; the status is an enum of exactly those, so the compiler holds the handler to it. What is left is
/// the *header fields* the handler returned. These are the functions the generated forwarder checks them
/// with, and the fixture proves the same behaviour over HTTP.
@Suite("Response tuples")
struct ResponseSelectionTests {
    private let fields: HTTPFields = [.eTag: "\"v1\"", .location: "/tasks/1"]

    @Test("an undocumented response is 500, whatever about it was undocumented")
    func undocumentedIs500() {
        let reasons: [WireOpenAPIUndocumentedResponse.Reason] = [
            .undeclaredHeader("x-stray"), .missingHeader("Location"),
        ]
        for reason in reasons {
            let error = WireOpenAPIUndocumentedResponse(operationID: "op", status: .accepted, reason: reason)
            #expect(error.httpStatus == .internalServerError)
            #expect(error.httpBody == nil)
        }
    }

    /// The document's spelling finds the field however the handler cased it, as field names compare.
    @Test("a declared header is read case-insensitively")
    func readsDeclaredHeader() throws {
        let read = try wireOpenAPIResponseHeader("ETAG", in: fields, required: false, operationID: "op", status: .ok)
        #expect(read == "\"v1\"")
    }

    @Test("an optional header the handler did not set is nil")
    func optionalAbsentIsNil() throws {
        let read = try wireOpenAPIResponseHeader(
            "X-Absent",
            in: fields,
            required: false,
            operationID: "op",
            status: .ok
        )
        #expect(read == nil)
    }

    @Test("a required header the handler did not set throws, naming it")
    func requiredAbsentThrows() {
        #expect(
            throws: WireOpenAPIUndocumentedResponse(
                operationID: "op",
                status: .created,
                reason: .missingHeader("X-Absent")
            )
        ) {
            try wireOpenAPIRequiredResponseHeader("X-Absent", in: fields, operationID: "op", status: .created)
        }
    }

    @Test("fields the response declares pass, in any case")
    func declaredFieldsPass() throws {
        try wireOpenAPICheckResponseHeaders(
            fields,
            declared: ["ETag", "Location"],
            operationID: "op",
            status: .ok
        )
    }

    /// A field with no generated member has nowhere to go, so it is refused rather than dropped.
    @Test("a field the response does not declare throws, naming it")
    func undeclaredFieldThrows() {
        #expect(
            throws: WireOpenAPIUndocumentedResponse(
                operationID: "op",
                status: .ok,
                reason: .undeclaredHeader("location")
            )
        ) {
            try wireOpenAPICheckResponseHeaders(fields, declared: ["ETag"], operationID: "op", status: .ok)
        }
    }

    /// The terminal's half of the forwarder's rethrow: a catch-all must not answer the service's breach.
    /// The runtime wraps a handler's throw in `ServerError`, so the check has to see through it.
    @Test("both service breaches are recognised, wrapped by the runtime or not")
    func serviceBreaches() {
        let undocumented = WireOpenAPIUndocumentedResponse(
            operationID: "op",
            status: .ok,
            reason: .undeclaredHeader("x-stray")
        )
        let invalid = WireOpenAPIResponseValidationError(operationID: "op", failures: [])
        let wrapped = ServerError(
            operationID: "op",
            request: HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/"),
            requestBody: nil,
            requestMetadata: .init(),
            causeDescription: "handler failed",
            underlyingError: undocumented
        )
        #expect(isServiceBreach(undocumented))
        #expect(isServiceBreach(invalid))
        #expect(isServiceBreach(wrapped))
        #expect(!isServiceBreach(WireOpenAPIRequestValidationError(operationID: "op", failures: [])))
    }
}
