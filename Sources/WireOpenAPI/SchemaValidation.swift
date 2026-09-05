import Foundation
public import HTTPTypes
@_spi(Generated) public import OpenAPIRuntime

// The runtime half of schema validation: the two errors a generated validator throws, and the
// accumulator it collects failures into. `WireOpenAPIGen` emits calls to these from each operation's
// forwarder; the types stay usable, and testable, on their own.
//
// See swift-wire's Notes/WireOpenAPIValidation.md. Two things from it are load-bearing here.
//
// **Two types, because one would be a bug.** `@ErrorResponse` matches by error type, and its clauses are
// emitted inside the same forwarder `do` that response validation throws from. A single shared type would
// make one controller-scope mapping — written for the obvious purpose of answering a bad request —
// silently catch response validation failures too, and answer a *service* bug with a client-error status,
// telling the caller they malformed a request that was fine. Nothing in the type system would object. So
// blame is carried in the type.
//
// **The statuses are not invented here.** `WireMVCBindingError.status` already answers a request that
// failed to bind, splitting by location: 422 for a malformed body, 400 for a missing or mismatched
// path/query/header value. A schema violation is that same failure one step later — the body parsed and
// is unacceptable, which is what 422 means — so it takes the same split, and a `@Get` route and an
// OpenAPI operation answer the same category of failure alike.

/// Where a violated assertion lives, which is what decides the status.
///
/// It mirrors `WireMVCBindingError`'s split rather than restating it in new terms: the vocabulary is
/// wire-mvc's, and this enum exists only because that one is a closed set of *binding* failures with no
/// case for "bound fine, violates the document".
public enum WireOpenAPIFailureLocation: String, Sendable, Equatable {
    case body
    case path
    case query
    case header

    /// Whether a failure here is about the request line rather than its payload.
    var isParameter: Bool { self != .body }
}

/// One violated assertion.
///
/// `path` is the **JSON** path, not the Swift one, and the two genuinely differ: an `allOf` member is
/// spelled `value1`/`value2` in the generated type but has no counterpart on the wire, because the
/// generated `init(from:)` decodes every member from the same decoder. A failure the emitter reaches at
/// `meta.value1.kind` is reported as `meta.kind`, because that is where the caller can find it.
public struct WireOpenAPIFailure: Sendable, Equatable {
    /// `body.items[3].name`, `query.page` — where the caller should look.
    public let path: String
    /// The assertion that failed, spelled as the document spells it: `minLength`, `pattern`.
    public let keyword: String
    /// What the document requires, rendered — `3`, `^[a-z]+$`.
    public let expected: String
    /// What arrived, rendered, when rendering it is safe and useful. Nil for a value not worth echoing.
    public let actual: String?
    public let location: WireOpenAPIFailureLocation

    public init(
        path: String,
        keyword: String,
        expected: String,
        actual: String? = nil,
        location: WireOpenAPIFailureLocation
    ) {
        self.path = path
        self.keyword = keyword
        self.expected = expected
        self.actual = actual
        self.location = location
    }
}

/// What a generated validator collects into: every failure, up to a cap.
///
/// Collect-all rather than fail-fast, because a caller should be able to fix every bad field in one
/// round-trip instead of one per round-trip. The cap is what makes that safe — a ten-thousand-element
/// array failing a `pattern` would otherwise produce ten thousand failures and a response body larger
/// than the request that caused it.
public struct WireOpenAPIFailureAccumulator: Sendable {
    /// The default cap. Generous enough that a real request never reaches it, small enough that a
    /// pathological one cannot turn a rejection into an outage.
    public static let defaultLimit = 100

    public private(set) var failures: [WireOpenAPIFailure] = []
    /// Whether the cap was reached and further failures went unrecorded — reported to the caller, so a
    /// truncated list never reads as a complete one.
    public private(set) var truncated = false
    private let limit: Int

    public init(limit: Int = WireOpenAPIFailureAccumulator.defaultLimit) { self.limit = limit }

    /// Whether the cap is reached. A generated walk checks this to stop descending, so a huge collection
    /// costs the walk rather than the walk plus the recording.
    public var isFull: Bool { failures.count >= limit }

    public mutating func record(_ failure: WireOpenAPIFailure) {
        guard !isFull else {
            truncated = true
            return
        }
        failures.append(failure)
    }

    public mutating func record(
        path: String,
        keyword: String,
        expected: String,
        actual: String? = nil,
        location: WireOpenAPIFailureLocation
    ) {
        record(
            WireOpenAPIFailure(
                path: path,
                keyword: keyword,
                expected: expected,
                actual: actual,
                location: location
            )
        )
    }

    /// The error for a request that violated the document, or nil when nothing did.
    public func requestError(operationID: String) -> WireOpenAPIRequestValidationError? {
        failures.isEmpty
            ? nil
            : WireOpenAPIRequestValidationError(
                operationID: operationID,
                failures: failures,
                truncated: truncated
            )
    }

    /// The error for a *response* that violated the document, or nil when nothing did.
    public func responseError(operationID: String) -> WireOpenAPIResponseValidationError? {
        failures.isEmpty
            ? nil
            : WireOpenAPIResponseValidationError(
                operationID: operationID,
                failures: failures,
                truncated: truncated
            )
    }
}

/// The caller broke the contract: a request the document describes as invalid.
///
/// Thrown inside the forwarder, where the operation's typed `Input` exists, so `@ErrorResponse` can map
/// it to one of the operation's **documented** responses. Unmapped, the conformance below answers it
/// directly — see the note on `httpBody`.
public struct WireOpenAPIRequestValidationError: Error, Sendable, HTTPResponseConvertible {
    public let operationID: String
    public let failures: [WireOpenAPIFailure]
    public let truncated: Bool

    public init(operationID: String, failures: [WireOpenAPIFailure], truncated: Bool = false) {
        self.operationID = operationID
        self.failures = failures
        self.truncated = truncated
    }

    /// 400 when any failure is in a parameter, 422 otherwise.
    ///
    /// Under collect-all one error can carry both kinds, and the parameter wins: a request whose path or
    /// query is wrong is malformed before its body's semantics are worth discussing.
    public var httpStatus: HTTPResponse.Status {
        failures.contains { $0.location.isParameter } ? .badRequest : .unprocessableContent
    }

    public var httpHeaderFields: HTTPFields { [.contentType: "application/json"] }

    /// The unmapped answer's body.
    ///
    /// This exists so that writing no `@ErrorResponse` at all still yields something a caller can act on,
    /// rather than a bare status or — as an unmapped throw would otherwise give — a dropped connection.
    /// It is deliberately the *lesser* path: a mapped `@ErrorResponse` builds one of the document's own
    /// responses and is serialised by the generator, which means it obeys the app's `@Coding` settings
    /// and appears in the document. This one cannot do either, because it is constructed outside any
    /// request's serializer. That asymmetry is the incentive to document the response.
    public var httpBody: HTTPBody? { encodedBody(failures: failures, truncated: truncated) }
}

/// The service broke its own contract: a response the document does not describe.
///
/// Always 500, and **never a body**. The caller did nothing wrong and can do nothing about it, so there
/// is no honest 4xx to answer with and nothing about the service's internals to hand over. The failures
/// are carried for logging and for `@ErrorResponse` to read, not for the wire.
public struct WireOpenAPIResponseValidationError: Error, Sendable, HTTPResponseConvertible {
    public let operationID: String
    public let failures: [WireOpenAPIFailure]
    public let truncated: Bool

    public init(operationID: String, failures: [WireOpenAPIFailure], truncated: Bool = false) {
        self.operationID = operationID
        self.failures = failures
        self.truncated = truncated
    }

    public var httpStatus: HTTPResponse.Status { .internalServerError }
}

// MARK: - the unmapped body

/// The wire shape, declared separately from `WireOpenAPIFailure` on purpose: the public type's property
/// names are Swift API and the JSON keys are a wire contract, and letting one rename the other is how a
/// refactor becomes a breaking change for every client.
private struct FailurePayload: Encodable {
    let path: String
    let keyword: String
    let expected: String
    let actual: String?
}

private struct ValidationPayload: Encodable {
    let errors: [FailurePayload]
    /// Present only when it is true, so the ordinary response carries no field explaining that nothing
    /// was omitted.
    let truncated: Bool?
}

private func encodedBody(failures: [WireOpenAPIFailure], truncated: Bool) -> HTTPBody? {
    let payload = ValidationPayload(
        errors: failures.map {
            FailurePayload(path: $0.path, keyword: $0.keyword, expected: $0.expected, actual: $0.actual)
        },
        truncated: truncated ? true : nil
    )
    let encoder = JSONEncoder()
    // Sorted so the output is stable: an unmapped rejection is the one response nobody configured, and a
    // body whose key order varies between identical requests is needlessly hard to test against.
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(payload) else { return nil }
    return HTTPBody([UInt8](data))
}

// MARK: - the decode-time seam

extension WireOpenAPIRequestValidationError {
    /// A body the *deserializer* rejected, expressed as the same failure a generated validator produces.
    ///
    /// Four things the document says about a body are enforced before the forwarder is ever entered, by
    /// the generated `init(from:)` rather than by anything here: `required`, each property's type,
    /// `additionalProperties: false`, and JSON being JSON at all. A `minLength` on the same schema is
    /// checked one step later. Left alone the two answer differently — 400 with an **empty body** for the
    /// first four, 422 with a list of what was wrong for the last — so a caller learns nothing from the
    /// more basic mistake and everything from the subtler one.
    ///
    /// Converting closes that. It also costs nothing in detail: there was none to lose, since the
    /// runtime's own answer carries no body at all, and a `DecodingError`'s `codingPath` is exactly the
    /// path a failure wants. 422 rather than 400 is not a new opinion either —
    /// `WireMVCBindingError.malformedBody` already answers 422 for a body it could not parse, so this is
    /// the two adapters agreeing rather than this one inventing a rule.
    ///
    /// What it cannot change is *where a mapping can be written*: the forwarder was never entered, so
    /// there is no `Output` to construct and no documented response to answer with. That part of the seam
    /// is structural.
    public init?(decoding error: any Error, operationID: String) {
        guard let decoding = error as? DecodingError else { return nil }
        let failure: WireOpenAPIFailure
        switch decoding {
        case .keyNotFound(let key, let context):
            failure = WireOpenAPIFailure(
                path: Self.path(context.codingPath + [key]),
                keyword: "required",
                expected: key.stringValue,
                location: .body
            )
        case .valueNotFound(let type, let context):
            failure = WireOpenAPIFailure(
                path: Self.path(context.codingPath),
                keyword: "required",
                expected: "\(type)",
                actual: "null",
                location: .body
            )
        case .typeMismatch(let type, let context):
            failure = WireOpenAPIFailure(
                path: Self.path(context.codingPath),
                keyword: "type",
                expected: "\(type)",
                location: .body
            )
        case .dataCorrupted(let context):
            // Where `additionalProperties: false` lands, and where malformed JSON lands. The debug
            // description is the only thing that distinguishes them and it is the decoder's wording, so
            // it is reported as-is rather than guessed at.
            failure = WireOpenAPIFailure(
                path: Self.path(context.codingPath),
                keyword: "invalid",
                expected: context.debugDescription,
                location: .body
            )
        @unknown default:
            failure = WireOpenAPIFailure(
                path: "body",
                keyword: "invalid",
                expected: "a decodable body",
                location: .body
            )
        }
        self.init(operationID: operationID, failures: [failure], truncated: false)
    }

    /// A `codingPath` rendered the way a generated validator renders one: `body.items[3].name`, with
    /// array indices in brackets rather than as segments.
    private static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce("body") { rendered, key in
            key.intValue.map { "\(rendered)[\($0)]" } ?? "\(rendered).\(key.stringValue)"
        }
    }
}
