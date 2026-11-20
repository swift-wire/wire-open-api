// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import HTTPTypes
// `MemberImportVisibility`: `ServerError` is the OpenAPI runtime's.
import OpenAPIRuntime
import Testing

@testable import WireOpenAPI

/// The terminal's half of the forwarder's rethrow: a catch-all must not answer the service's breach.
@Suite("Service breaches")
struct ServiceBreachTests {
    /// The runtime wraps a handler's throw in `ServerError`, so the check has to see through it.
    @Test("a response validation failure is recognised, wrapped by the runtime or not")
    func serviceBreaches() {
        let invalid = WireOpenAPIResponseValidationError(operationID: "op", failures: [])
        let wrapped = ServerError(
            operationID: "op",
            request: HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/"),
            requestBody: nil,
            requestMetadata: .init(),
            causeDescription: "handler failed",
            underlyingError: invalid
        )
        #expect(isServiceBreach(invalid))
        #expect(isServiceBreach(wrapped))
        #expect(!isServiceBreach(WireOpenAPIRequestValidationError(operationID: "op", failures: [])))
    }
}
