// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-open-api project authors

import HTTPTypes
// `MemberImportVisibility`: this file reads `httpBody` off a failure and collects an `HTTPBody`,
// both declared by the OpenAPI runtime, so it imports the module that declares them rather than
// relying on one reaching it through `WireOpenAPI`.
import OpenAPIRuntime
import Testing

@testable import WireOpenAPI

/// The runtime half of schema validation (slice 1), before any emitter exists.
///
/// What is worth asserting here is the part that is *decided* rather than walked: which status a failure
/// set earns, and that collecting them cannot become unbounded. The walk itself is generated code and
/// belongs to a later slice; the fixture proves the wire behaviour end to end.
@Suite("Schema validation")
struct SchemaValidationTests {
    private func failure(_ location: WireOpenAPIFailureLocation) -> WireOpenAPIFailure {
        WireOpenAPIFailure(path: "x", keyword: "minLength", expected: "1", location: location)
    }

    private func error(_ locations: [WireOpenAPIFailureLocation]) -> WireOpenAPIRequestValidationError {
        WireOpenAPIRequestValidationError(operationID: "op", failures: locations.map(failure))
    }

    /// A body violation is 422 — the body parsed and is unacceptable, which is what
    /// `WireMVCBindingError.malformedBody` already answers for a body that would not parse.
    @Test("a body violation is 422")
    func bodyIs422() {
        #expect(error([.body]).httpStatus == .unprocessableContent)
    }

    /// A parameter violation is 400, matching `WireMVCBindingError.pathParameterTypeMismatch` and its
    /// siblings. Every location that is not the body takes it.
    @Test(
        "a parameter violation is 400",
        arguments: [WireOpenAPIFailureLocation.path, .query, .header]
    )
    func parameterIs400(location: WireOpenAPIFailureLocation) {
        #expect(error([location]).httpStatus == .badRequest)
    }

    /// The mixed case, which only exists because failures are collected rather than thrown at the first.
    /// The parameter wins: a request whose path is wrong is malformed before its body's semantics are
    /// worth discussing. Asserted in both orders, so the answer cannot come from whichever happened to be
    /// recorded first.
    @Test("a parameter violation wins over a body violation, in either order")
    func mixedPrefersParameter() {
        #expect(error([.body, .query]).httpStatus == .badRequest)
        #expect(error([.query, .body]).httpStatus == .badRequest)
    }

    /// The service's own breach is always 500 and never carries a body — the caller did nothing wrong and
    /// can do nothing about it, so there is no honest 4xx and nothing of the service's internals to hand
    /// over. The failures are still carried, for logging and for `@ErrorResponse` to read.
    @Test("a response violation is 500 with no body")
    func responseIs500() {
        let error = WireOpenAPIResponseValidationError(operationID: "op", failures: [failure(.body)])
        #expect(error.httpStatus == .internalServerError)
        #expect(error.httpBody == nil)
    }

    /// Nothing recorded is not an error. The generated walk always runs, so this is the ordinary path.
    @Test("an empty accumulator yields no error")
    func emptyIsNotAnError() {
        let accumulator = WireOpenAPIFailureAccumulator()
        #expect(accumulator.requestError(operationID: "op") == nil)
        #expect(accumulator.responseError(operationID: "op") == nil)
    }

    /// The cap is what makes collect-all safe: a ten-thousand-element array failing a `pattern` would
    /// otherwise produce a response body larger than the request that caused it. Reaching it is reported
    /// rather than silent, so a truncated list never reads as a complete one.
    @Test("the cap bounds what is collected, and says so")
    func capIsEnforcedAndReported() {
        var accumulator = WireOpenAPIFailureAccumulator(limit: 3)
        for _ in 0..<10 { accumulator.record(failure(.body)) }
        #expect(accumulator.failures.count == 3)
        #expect(accumulator.truncated)
        #expect(accumulator.isFull)
        #expect(accumulator.requestError(operationID: "op")?.truncated == true)
    }

    /// Below the cap nothing is flagged — the common case, and the one a client should be able to trust
    /// as complete.
    @Test("under the cap nothing is reported as truncated")
    func underCapIsNotTruncated() {
        var accumulator = WireOpenAPIFailureAccumulator(limit: 3)
        accumulator.record(failure(.query))
        #expect(!accumulator.truncated)
        #expect(!accumulator.isFull)
        #expect(accumulator.requestError(operationID: "op")?.truncated == false)
    }

    /// The unmapped answer has to be something a caller can act on, since by definition no
    /// `@ErrorResponse` shaped it. Keys are sorted so identical requests give identical bytes.
    @Test("the unmapped body carries the failures")
    func unmappedBodyCarriesFailures() async throws {
        let error = WireOpenAPIRequestValidationError(
            operationID: "op",
            failures: [
                WireOpenAPIFailure(
                    path: "body.title",
                    keyword: "minLength",
                    expected: "3",
                    actual: "ab",
                    location: .body
                )
            ]
        )
        let body = try #require(error.httpBody)
        let rendered = String(decoding: try await [UInt8](collecting: body, upTo: 4096), as: UTF8.self)
        #expect(
            rendered == #"{"errors":[{"actual":"ab","expected":"3","keyword":"minLength","path":"body.title"}]}"#
        )
        #expect(error.httpHeaderFields[.contentType] == "application/json")
    }

    /// `truncated` is absent rather than `false` when nothing was dropped: the ordinary response should
    /// not carry a field explaining that nothing was omitted.
    @Test("the unmapped body mentions truncation only when it happened")
    func truncationAppearsOnlyWhenTrue() async throws {
        let error = WireOpenAPIRequestValidationError(
            operationID: "op",
            failures: [failure(.body)],
            truncated: true
        )
        let body = try #require(error.httpBody)
        let rendered = String(decoding: try await [UInt8](collecting: body, upTo: 4096), as: UTF8.self)
        #expect(rendered.contains(#""truncated":true"#))
    }
}

/// The decode-time seam: four things the document says about a body are enforced by the generated
/// `init(from:)` before the forwarder is entered, and they used to answer 400 with an empty body while a
/// `minLength` on the same schema answered 422 with a list. These assert the conversion that closes that.
@Suite("Decode-time conversion")
struct DecodeConversionTests {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(_ name: String) {
            self.stringValue = name
            self.intValue = nil
        }
        init(_ index: Int) {
            self.stringValue = "\(index)"
            self.intValue = index
        }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { self.init(intValue) }
    }

    private func converted(_ error: DecodingError) -> WireOpenAPIRequestValidationError? {
        WireOpenAPIRequestValidationError(decoding: error, operationID: "op")
    }

    /// A property the document requires and the body omitted.
    @Test("a missing key becomes a required failure, named")
    func keyNotFound() throws {
        let error = try #require(
            converted(
                .keyNotFound(Key("title"), .init(codingPath: [], debugDescription: ""))
            )
        )
        #expect(error.failures.map(\.keyword) == ["required"])
        #expect(error.failures.first?.path == "body.title")
        // A body violation, so 422 — the same answer a `minLength` on the same schema earns.
        #expect(error.httpStatus == .unprocessableContent)
    }

    @Test("a type mismatch names the type the document asked for")
    func typeMismatch() throws {
        let error = try #require(
            converted(
                .typeMismatch(String.self, .init(codingPath: [Key("id")], debugDescription: ""))
            )
        )
        #expect(error.failures.map(\.keyword) == ["type"])
        #expect(error.failures.first?.expected == "String")
        #expect(error.failures.first?.path == "body.id")
    }

    /// Where `additionalProperties: false` lands, and malformed JSON with it. The decoder's own wording is
    /// the only thing separating them, so it is reported rather than guessed at.
    @Test("corrupted data carries the decoder's own description")
    func dataCorrupted() throws {
        let error = try #require(
            converted(.dataCorrupted(.init(codingPath: [], debugDescription: "not valid JSON")))
        )
        #expect(error.failures.map(\.keyword) == ["invalid"])
        #expect(error.failures.first?.expected == "not valid JSON")
    }

    /// An index in the coding path is rendered in brackets, so a decode failure inside a collection reads
    /// exactly like the generated validator's `body.subtasks[1].title`.
    @Test("an index in the path is rendered in brackets, as a generated check renders it")
    func indexedPath() throws {
        let error = try #require(
            converted(
                .keyNotFound(
                    Key("title"),
                    .init(codingPath: [Key("subtasks"), Key(1)], debugDescription: "")
                )
            )
        )
        #expect(error.failures.first?.path == "body.subtasks[1].title")
    }

    /// Only decode failures convert. A missing body or a wrong content type is a *transport* failure and
    /// keeps the runtime's own 400/415, which is what `WireMVCBindingError` answers for the same thing.
    @Test("anything that is not a DecodingError is left alone")
    func othersAreNotConverted() {
        struct Other: Error {}
        #expect(WireOpenAPIRequestValidationError(decoding: Other(), operationID: "op") == nil)
    }
}
