// swift-format-ignore-file
//
// SPDX-License-Identifier: Apache-2.0
//
// Copyright (c) 2023 Apple Inc. and the SwiftOpenAPIGenerator project authors
// Copyright (c) 2026 the wire-open-api project authors
//
// A transcription of `Sources/_OpenAPIGeneratorCore/Translator/Responses/HTTPStatusCodes.swift`
// from the SwiftOpenAPIGenerator project (https://github.com/apple/swift-openapi-generator),
// used under Apache License v2.0. Modified for use in this package.
// See NOTICE for attribution.
//
// Excluded from swift-format and SwiftLint (see .swiftlint.yml), for the reason `GeneratorSafeNames` is:
// this is a transcription, and its value is that a diff against upstream stays readable.
//
// ┌───────────────────────────────────────────────────────────────────────────────────────────────┐
// │ COPIED LOGIC — do not edit to taste.                                                          │
// │                                                                                               │
// │ A transcription of swift-openapi-generator's `HTTPStatusCodes.swift`                          │
// │ (`Sources/_OpenAPIGeneratorCore/Translator/Responses/HTTPStatusCodes.swift`).                 │
// └───────────────────────────────────────────────────────────────────────────────────────────────┘
//
// The typed shim constructs an operation's response — `.ok(…)`, `.created(…)`, `.noContent(…)` — so it
// has to name the `Output` case the generator emitted for a status code. Unlike `GeneratorSafeNames`
// this is pure data, a flat switch with a `code<N>` fallback, which makes it far cheaper to carry: there
// is no algorithm to diverge, only entries to gain.
//
// Held by the same mechanism: `swift run NamingGoldenTool` generates a document declaring every status
// from 100 to 599, reads back the case name the generator emitted for each, and writes
// `status-golden.tsv`. A status whose name changes, or one the generator learns to name, fails CI.
//
// Note `100`: the generator emits a backticked `` `continue` ``, because the unbackticked spelling is a
// keyword. The backticks are part of the emitted name and are reproduced verbatim.

/// A namespace for known HTTP status codes.
public enum GeneratorStatusNames {

    /// The `Output` case the generator emits for a status code.
    public static func safeName(for code: Int) -> String {
        switch code {
        case 100: return "`continue`"
        case 101: return "switchingProtocols"
        case 103: return "earlyHints"
        case 200: return "ok"
        case 201: return "created"
        case 202: return "accepted"
        case 203: return "nonAuthoritativeInformation"
        case 204: return "noContent"
        case 205: return "resetContent"
        case 206: return "partialContent"
        case 300: return "multipleChoices"
        case 301: return "movedPermanently"
        case 302: return "found"
        case 303: return "seeOther"
        case 304: return "notModified"
        case 307: return "temporaryRedirect"
        case 308: return "permanentRedirect"
        case 400: return "badRequest"
        case 401: return "unauthorized"
        case 403: return "forbidden"
        case 404: return "notFound"
        case 405: return "methodNotAllowed"
        case 406: return "notAcceptable"
        case 407: return "proxyAuthenticationRequired"
        case 408: return "requestTimeout"
        case 409: return "conflict"
        case 410: return "gone"
        case 411: return "lengthRequired"
        case 412: return "preconditionFailed"
        case 413: return "contentTooLarge"
        case 414: return "uriTooLong"
        case 415: return "unsupportedMediaType"
        case 416: return "rangeNotSatisfiable"
        case 417: return "expectationFailed"
        case 421: return "misdirectedRequest"
        case 422: return "unprocessableContent"
        case 425: return "tooEarly"
        case 426: return "upgradeRequired"
        case 428: return "preconditionRequired"
        case 429: return "tooManyRequests"
        case 431: return "requestHeaderFieldsTooLarge"
        case 451: return "unavailableForLegalReasons"
        case 500: return "internalServerError"
        case 501: return "notImplemented"
        case 502: return "badGateway"
        case 503: return "serviceUnavailable"
        case 504: return "gatewayTimeout"
        case 505: return "httpVersionNotSupported"
        case 511: return "networkAuthenticationRequired"
        default: return "code\(code)"
        }
    }
}
