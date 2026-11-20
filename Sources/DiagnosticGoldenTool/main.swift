// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Foundation

// Gates the diagnostics WireOpenAPIGen *rejects* with — the half the fixture cannot cover.
//
// The fixture proves the accept paths: it builds, so every mapping in it is legal. Nothing proves the
// reject paths, because gating those needs a build that is expected to fail, and a test target cannot
// express "this must not compile". So they were unguarded, and an emitter change could quietly stop
// diagnosing something — which does not fail anything, it just moves the failure into generated code at
// a line nobody wrote. That is the failure mode this exists to prevent.
//
//     swift run DiagnosticGoldenTool            # rewrite the golden
//     swift run DiagnosticGoldenTool --check    # fail if a diagnostic changed or stopped firing
//
// A subprocess rather than a test, for the same reason `NamingGoldenTool` is one: WireOpenAPIGen is an
// executable and cannot be imported, and its contract here is its *exit code and stderr*, which is what
// a caller actually sees. Running it is the only honest way to assert that.
//
// The golden holds the messages verbatim. That is deliberate: a diagnostic that still fires but has
// become useless is a regression too, and a wording change should be visible in review rather than
// silent. Cases are run in a temp directory with relative paths, so nothing machine-specific leaks in.

// MARK: - locations

/// Derived from `#filePath`, so the tool behaves the same however it is invoked.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let goldenURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("diagnostics-golden.txt")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// The built `WireOpenAPIGen`, located rather than launched through `swift run`.
///
/// Nesting `swift run` inside `swift run` would have both invocations contend for the same package's
/// build lock — the reason `NamingGoldenTool` gets away with it is that the generator it runs is a
/// *different* package with its own `.build`. So this finds the binary instead, across both the
/// Xcode-style and the classic build layouts, and across this package's build and the fixture's (where
/// the plugin already builds it).
let generatorBinary: URL = {
    if let override = ProcessInfo.processInfo.environment["WIRE_OPENAPI_GEN_PATH"] {
        return URL(fileURLWithPath: override)
    }
    // Beside this tool, first: if both were built together, that is certainly the current one.
    let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("WireOpenAPIGen")
    let candidates =
        [sibling]
        + [
            ".build/out/Products/Debug/WireOpenAPIGen",
            ".build/debug/WireOpenAPIGen",
            ".build/release/WireOpenAPIGen",
            "Fixtures/.build/out/Products/Debug/WireOpenAPIGen",
            "Fixtures/.build/debug/WireOpenAPIGen",
        ].map { repoRoot.appendingPathComponent($0) }
    guard
        let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        })
    else {
        fail(
            """
            cannot find a built WireOpenAPIGen. Build it first:

                swift build --product WireOpenAPIGen

            or point WIRE_OPENAPI_GEN_PATH at one.
            """
        )
    }
    warnIfStale(found)
    return found
}()

/// Refuse a binary older than the code it is meant to be testing.
///
/// The tool *locates* WireOpenAPIGen rather than building it (see above), which means an edit to a
/// diagnostic followed by `swift run DiagnosticGoldenTool` silently tests the previous build — and
/// happily writes a golden recording the old messages as if they were current. That is a worse failure
/// than a stale build, because the table is then wrong *and* self-consistent. Caught twice while writing
/// slice 3, which is twice more than it should catch anyone else.
///
/// Conservative by design: it compares modification times, so touching a source without changing it
/// trips it even though SwiftPM correctly skipped the relink. Erring toward "build it again" is the right
/// side to err on, since the message says exactly what to run.
func warnIfStale(_ binary: URL) {
    let sources = repoRoot.appendingPathComponent("Sources/WireOpenAPIGen")
    guard
        let built = try? binary.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate,
        let walker = FileManager.default.enumerator(atPath: sources.path)
    else { return }
    let newest = walker.compactMap { entry -> Date? in
        guard let name = entry as? String, name.hasSuffix(".swift") else { return nil }
        return try? sources.appendingPathComponent(name)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    .max()
    guard let newest, newest > built else { return }
    fail(
        """
        \(binary.path)
        is older than Sources/WireOpenAPIGen, so this would test the previous build and write a golden
        that records it. Build it first:

            swift build --product WireOpenAPIGen
        """
    )
}

// MARK: - the corpus

/// What an operation's 404 looks like. The pair/closure choice is decided by whether a response carries a
/// body, so that is the axis every form diagnostic turns on.
enum Response404 {
    /// No 404 at all — for the status-not-declared diagnostics.
    case absent
    /// A 404 carrying a JSON body, so only the closure form can construct it.
    case bodied
    /// A 404 carrying nothing, so only the pair form can.
    case bare
    /// A 404 this adapter cannot build at all.
    case xml
}

/// A document declaring one `get` per entry, all under `/`-prefixed paths named for the operation.
func document(_ operations: [(id: String, response: Response404)]) -> String {
    var lines = ["openapi: 3.1.0", "info: { title: Gate, version: 1.0.0 }", "paths:"]
    for (id, response) in operations {
        lines.append("  /\(id):")
        lines.append("    get:")
        lines.append("      operationId: \(id)")
        lines.append("      responses:")
        lines.append("        '200': { description: ok }")
        switch response {
        case .absent: break
        case .bare: lines.append("        '404': { description: gone }")
        case .bodied:
            lines.append("        '404':")
            lines.append("          description: gone")
            lines.append("          content:")
            lines.append("            application/json:")
            lines.append("              schema: { $ref: '#/components/schemas/Problem' }")
        case .xml:
            lines.append("        '404':")
            lines.append("          description: gone")
            lines.append("          content:")
            lines.append("            application/xml:")
            lines.append("              schema: { $ref: '#/components/schemas/Problem' }")
        }
    }
    lines.append("components:")
    lines.append("  schemas:")
    lines.append("    Problem:")
    lines.append("      type: object")
    lines.append("      required: [message]")
    lines.append("      properties: { message: { type: string } }")
    return lines.joined(separator: "\n") + "\n"
}

/// A controller implementing every operation the document declares — coverage is its own diagnostic, and
/// tripping it would mask the one under test.
/// `raw` takes the operations with `@RawOperation` instead of `@Operation`. The body cases need it —
/// a typed handler must bind a documented body and these cases are not about binding — and it doubles as
/// the check that validation is emitted for a raw operation, which receives the same `Input`.
func controller(
    typeAttributes: [String] = [],
    raw: Bool = false,
    operations: [(id: String, attributes: [String])]
) -> String {
    var lines = [
        "import Wire", "import WireOpenAPI", "", "struct Gone: Error {}", "",
        "@Singleton", "@OpenAPIController",
    ]
    lines += typeAttributes
    lines.append("struct GateController {")
    for (id, attributes) in operations {
        lines.append(raw ? "    @RawOperation" : "    @Operation")
        lines += attributes.map { "    " + $0 }
        if raw {
            let type = id.prefix(1).uppercased() + id.dropFirst()
            lines.append(
                "    func \(id)(_ input: Operations.\(type).Input) async throws "
                    + "-> Operations.\(type).Output { .ok }"
            )
        } else {
            lines.append("    func \(id)() async throws { throw Gone() }")
        }
        lines.append("")
    }
    lines.append("}")
    return lines.joined(separator: "\n") + "\n"
}

let problemBody = #"{ _ in Components.Schemas.Problem(message: "x") }"#

/// A document whose single operation *returns* the given schema. The mirror of `bodyDocument`, for the
/// diagnostics that only apply to what a handler produces.
func responseDocument(_ schema: String) -> String {
    """
    openapi: 3.1.0
    info: { title: Gate, version: 1.0.0 }
    paths:
      /opA:
        get:
          operationId: opA
          responses:
            '200': { description: ok, content: { application/json: { schema: \(schema) } } }
    """
}

/// A document whose single operation takes a JSON request body with the given schema, written in YAML
/// flow style so it stays on one line — the same shape `parameterDocument` uses, and one less thing to
/// get wrong than block indentation inside a Swift multiline literal.
func bodyDocument(_ schema: String) -> String {
    """
    openapi: 3.1.0
    info: { title: Gate, version: 1.0.0 }
    paths:
      /opA:
        post:
          operationId: opA
          requestBody:
            required: true
            content: { application/json: { schema: \(schema) } }
          responses:
            '200': { description: ok }
    """
}

/// A document whose single operation takes one query parameter with the given schema — for the assertion
/// diagnostics, which are about a parameter rather than a response.
func parameterDocument(_ schema: String) -> String {
    """
    openapi: 3.1.0
    info: { title: Gate, version: 1.0.0 }
    paths:
      /opA:
        get:
          operationId: opA
          parameters:
            - { name: q, in: query, schema: \(schema) }
          responses:
            '200': { description: ok }
    """
}

/// A document whose single operation `opA` declares the given responses, each written in YAML flow style
/// under its status — for the response-tuple diagnostics, which turn on which successes are documented
/// and what each carries.
func responsesDocument(_ responses: [(code: Int, response: String)]) -> String {
    var lines = [
        "openapi: 3.1.0", "info: { title: Gate, version: 1.0.0 }", "paths:", "  /opA:", "    get:",
        "      operationId: opA", "      responses:",
    ]
    lines += responses.map { "        '\($0.code)': \($0.response)" }
    return lines.joined(separator: "\n") + "\n"
}

let jsonTask = "description: ok, content: { application/json: { schema: { type: string } } }"

/// The status enum `opA`'s response tuple names, spelled as the idiomatic naming strategy these cases
/// take by default resolves the operation's namespace.
let opAStatus = "Operations.OpA.SuccessStatus"

/// Where swift-openapi-generator puts `opA`'s responses, under the same strategy.
let opAOutput = "Operations.OpA.Output"

/// A controller whose single typed `opA` returns `returnType`, under `attributes`, beside a declaration of
/// `opAStatus` with `statusCases` when there are any. The body is a `fatalError`: these cases are refused
/// before anything is compiled, and the accept case is not compiled by the tool at all.
func tupleController(_ returnType: String, attributes: [String] = [], statusCases: [String] = []) -> String {
    var lines = [
        "import HTTPTypes", "import Wire", "import WireOpenAPI", "", "@Singleton", "@OpenAPIController",
        "struct GateController {", "    @Operation",
    ]
    lines += attributes.map { "    " + $0 }
    lines += ["    func opA() async throws -> \(returnType) { fatalError() }", "}"]
    if !statusCases.isEmpty {
        lines += [
            "", "extension Operations.OpA {", "    enum SuccessStatus: Sendable, Hashable {",
        ]
        lines += statusCases.map { "        case \($0)" }
        lines += ["    }", "}"]
    }
    return lines.joined(separator: "\n") + "\n"
}

struct Gate {
    let name: String
    /// Why this case exists, carried into the golden so a reader of the table knows what it protects.
    let summary: String
    let document: String
    let controller: String
    /// The contents of a `wire-openapi.yaml` beside the document, when the case needs one. Nil means the
    /// file is absent, which is how a document says nothing and takes every default.
    var settings: String?
}

let gates: [Gate] = [
    Gate(
        name: "route-scope/status-not-declared",
        summary: "a mapped error is answered as one of the operation's own responses",
        document: document([("opA", .absent)]),
        controller: controller(operations: [("opA", ["@ErrorResponse(Gone.self, .notFound)"])])
    ),
    Gate(
        name: "route-scope/pair-form-against-a-bodied-response",
        summary: "a bare case cannot construct a response the document gives a body",
        document: document([("opA", .bodied)]),
        controller: controller(operations: [("opA", ["@ErrorResponse(Gone.self, .notFound)"])])
    ),
    Gate(
        name: "route-scope/closure-form-against-a-bare-response",
        summary: "a response carrying nothing has nowhere to put a body",
        document: document([("opA", .bare)]),
        controller: controller(
            operations: [("opA", ["@ErrorResponse(Gone.self, .notFound, \(problemBody))"])]
        )
    ),
    Gate(
        name: "route-scope/terminal-scoped-pair-form-against-a-bodied-response",
        summary: """
            a terminal-scoped mapping is exempt from naming a declared status, but not from the form of \
            one the document does declare — it still gets a forwarder clause
            """,
        document: document([("opA", .bodied)]),
        controller: controller(
            operations: [("opA", ["@ErrorResponse(DecodingError.self, .notFound)"])]
        )
    ),
    Gate(
        name: "route-scope/unconstructible-content-type",
        summary: "the shim builds JSON bodies only",
        document: document([("opA", .xml)]),
        controller: controller(
            operations: [("opA", ["@ErrorResponse(Gone.self, .notFound, \(problemBody))"])]
        )
    ),
    Gate(
        name: "controller-scope/status-not-declared-for-some-operations",
        summary: "a controller mapping covers every operation, so every one has to declare the status",
        document: document([("opA", .bare), ("opB", .absent)]),
        controller: controller(
            typeAttributes: ["@ErrorResponse(Gone.self, .notFound)"],
            operations: [("opA", []), ("opB", [])]
        )
    ),
    Gate(
        name: "controller-scope/pair-form-against-a-bodied-response",
        summary: "the form check applies at controller scope too, which it did not before",
        document: document([("opA", .bodied)]),
        controller: controller(
            typeAttributes: ["@ErrorResponse(Gone.self, .notFound)"],
            operations: [("opA", [])]
        )
    ),
    Gate(
        name: "controller-scope/closure-form-against-a-bare-response",
        summary: "and in the other direction",
        document: document([("opA", .bare)]),
        controller: controller(
            typeAttributes: ["@ErrorResponse(Gone.self, .notFound, \(problemBody))"],
            operations: [("opA", [])]
        )
    ),
    Gate(
        name: "controller-scope/covered-operations-disagree-about-a-body",
        summary: """
            the failure only controller scope can have: no form serves both, so the fix is to move the \
            mapping rather than to change it
            """,
        document: document([("opA", .bodied), ("opB", .bare)]),
        controller: controller(
            typeAttributes: ["@ErrorResponse(Gone.self, .notFound)"],
            operations: [("opA", []), ("opB", [])]
        )
    ),
    Gate(
        name: "controller-scope/unconstructible-content-type",
        summary: "reported before the pair/closure question, which has no right answer here",
        document: document([("opA", .xml)]),
        controller: controller(
            typeAttributes: ["@ErrorResponse(Gone.self, .notFound, \(problemBody))"],
            operations: [("opA", [])]
        )
    ),
    Gate(
        name: "ordering/catch-all-is-not-last",
        summary: "a catch-all matches everything, so anything after it is dead",
        document: document([("opA", .bare)]),
        controller: controller(
            operations: [
                (
                    "opA",
                    [
                        "@ErrorResponse(Swift.Error.self, .notFound)",
                        "@ErrorResponse(Gone.self, .notFound)",
                    ]
                )
            ]
        )
    ),
    // Slice 2's reject paths. The document asks for a check the adapter cannot make, and saying so is
    // the whole point: a document that declares an assertion and gets no enforcement is the failure the
    // capability exists to remove, so producing that *silently* would be worse than the gap it replaced.
    Gate(
        name: "parameters/assertion-on-a-type-the-format-changed",
        summary:
            "`format: date-time` is emitted as a Foundation.Date, so a string assertion has nothing to "
            + "measure — the value is not a string by the time a check could run",
        document: parameterDocument("{ type: string, format: date-time, minLength: 5 }"),
        controller: controller(operations: [("opA", [])])
    ),
    Gate(
        name: "parameters/pattern-swift-cannot-compile",
        summary:
            "patterns are compiled at build time, so an unreadable one fails the build naming the "
            + "parameter rather than trapping on the first request that reaches it",
        document: parameterDocument("{ type: string, pattern: '[a-' }"),
        controller: controller(operations: [("opA", [])])
    ),
    Gate(
        name: "schemas/property-count-bounds",
        summary:
            "a generated struct has a fixed set of members and no runtime property count — and the bound "
            + "is only reported when it says more than `required:` already does",
        document: bodyDocument(
            "{ type: object, minProperties: 2, properties: { a: { type: string }, b: { type: string } } }"
        ),
        controller: controller(raw: true, operations: [("opA", [])])
    ),
    Gate(
        name: "schemas/assertion-beneath-a-oneOf",
        summary:
            "the generator emits a oneOf as an enum whose case names this adapter does not derive, so an "
            + "assertion underneath one is refused rather than guessed at",
        document: bodyDocument(
            "{ oneOf: [ { type: object, properties: { a: { type: string, minLength: 3 } } }, "
                + "{ type: object, properties: { b: { type: string } } } ] }"
        ),
        controller: controller(raw: true, operations: [("opA", [])])
    ),
    // Slice 5, and the pair is the point: the *same* document, differing only by whether
    // `wire-openapi.yaml` asks for responses to be checked. Together they gate the request-reachability
    // rule in both directions — a constraint reachable only from a response must fail the build for
    // someone who asked for the check, and must not for anyone who did not.
    Gate(
        name: "responses/unrepresentable-when-responses-are-checked",
        summary: "turning response validation on widens the walk, and may turn a passing build failing",
        document: responseDocument("{ type: object, minProperties: 2, properties: { a: { type: string } } }"),
        controller: controller(raw: true, operations: [("opA", [])]),
        settings: "validatesResponses: true\n"
    ),
    Gate(
        name: "responses/unrepresentable-when-they-are-not",
        summary: "the same document builds when nobody asked for the check — the other half of the rule",
        document: responseDocument("{ type: object, minProperties: 2, properties: { a: { type: string } } }"),
        controller: controller(raw: true, operations: [("opA", [])])
    ),
    // Choosing a response: a status enum of the documented successes, each case carrying its response's
    // generated headers, or — with no status to choose — the one success's headers.
    Gate(
        name: "tuple/status-with-one-success",
        summary: "a returned status chooses among documented successes, so one success leaves no choice",
        document: responsesDocument([(200, "{ \(jsonTask) }")]),
        controller: tupleController("(status: \(opAStatus), body: String)", statusCases: ["ok"])
    ),
    Gate(
        name: "tuple/status-with-one-headered-bodiless-success",
        summary: "the remedy for one success is its own form: here, its generated headers returned bare",
        document: responsesDocument([
            (204, "{ description: done, headers: { X-Count: { required: true, schema: { type: integer } } } }")
        ]),
        controller: tupleController(opAStatus, statusCases: ["noContent(\(opAOutput).NoContent.Headers)"])
    ),
    Gate(
        name: "tuple/status-with-no-success",
        summary: "with no documented success, no return shape helps; only the document can",
        document: responsesDocument([(400, "{ description: bad }")]),
        controller: tupleController(opAStatus, statusCases: ["badRequest"])
    ),
    Gate(
        name: "tuple/status-beside-an-annotation",
        summary: "a status returned and a status annotated contradict each other",
        document: responsesDocument([(200, "{ \(jsonTask) }"), (201, "{ \(jsonTask) }")]),
        controller: tupleController(
            "(status: \(opAStatus), body: String)",
            attributes: ["@JSONResponse(status: .created)"],
            statusCases: ["ok", "created"]
        )
    ),
    Gate(
        name: "tuple/successes-disagree-on-a-body",
        summary: "the handler has one body to answer every success with, so all must agree on carrying one",
        document: responsesDocument([(200, "{ \(jsonTask) }"), (204, "{ description: none }")]),
        controller: tupleController("(status: \(opAStatus), body: String)", statusCases: ["ok", "noContent"])
    ),
    Gate(
        name: "tuple/not-a-response-shape",
        summary: "the labels are read in WireMVC's canonical order, and anything else is not a response tuple",
        document: responsesDocument([(200, "{ \(jsonTask) }"), (201, "{ \(jsonTask) }")]),
        controller: tupleController("(body: String, status: \(opAStatus))")
    ),
    Gate(
        name: "tuple/status-is-an-http-response-status",
        summary: "a WireMVC route's status type would let the handler return one the document does not declare",
        document: responsesDocument([
            (200, "{ \(jsonTask), headers: { ETag: { schema: { type: string } } } }"),
            (201, "{ \(jsonTask), headers: { Location: { required: true, schema: { type: string } } } }"),
        ]),
        controller: tupleController("(status: HTTPResponse.Status, body: String)")
    ),
    Gate(
        name: "tuple/status-enum-not-declared",
        summary: "the cases are checked against the document, so the enum has to be one this build can read",
        document: responsesDocument([(200, "{ \(jsonTask) }"), (201, "{ \(jsonTask) }")]),
        controller: tupleController("(status: \(opAStatus), body: String)")
    ),
    Gate(
        name: "tuple/status-enum-cases-differ",
        summary: "the enum is what the compiler holds the handler to, so it must be exactly the successes",
        document: responsesDocument([(200, "{ \(jsonTask) }"), (201, "{ \(jsonTask) }")]),
        controller: tupleController("(status: \(opAStatus), body: String)", statusCases: ["ok", "accepted"])
    ),
    Gate(
        name: "tuple/http-fields-beside-a-status",
        summary: "WireMVC's (status:headers:body:) is not an operation's shape: headers travel in the cases",
        document: responsesDocument([
            (200, "{ \(jsonTask), headers: { ETag: { schema: { type: string } } } }"),
            (201, "{ \(jsonTask), headers: { Location: { required: true, schema: { type: string } } } }"),
        ]),
        controller: tupleController(
            "(status: \(opAStatus), headers: HTTPFields, body: String)",
            statusCases: ["ok(\(opAOutput).Ok.Headers)", "created(\(opAOutput).Created.Headers)"]
        )
    ),
    Gate(
        name: "tuple/case-without-its-headers",
        summary: "a headered response's case must carry its headers, or the response could not be built",
        document: responsesDocument([
            (200, "{ \(jsonTask), headers: { ETag: { schema: { type: string } } } }"),
            (201, "{ \(jsonTask), headers: { Location: { required: true, schema: { type: string } } } }"),
        ]),
        controller: tupleController(
            "(status: \(opAStatus), body: String)",
            statusCases: ["ok(\(opAOutput).Ok.Headers)", "created"]
        )
    ),
    Gate(
        name: "tuple/case-with-the-wrong-headers",
        summary: "a case carries exactly its own response's headers, not another response's",
        document: responsesDocument([
            (200, "{ \(jsonTask), headers: { ETag: { schema: { type: string } } } }"),
            (201, "{ \(jsonTask), headers: { Location: { required: true, schema: { type: string } } } }"),
        ]),
        controller: tupleController(
            "(status: \(opAStatus), body: String)",
            statusCases: ["ok(\(opAOutput).Ok.Headers)", "created(\(opAOutput).Ok.Headers)"]
        )
    ),
    Gate(
        name: "tuple/case-with-headers-its-response-lacks",
        summary: "a response declaring no headers has no Headers type for its case to carry",
        document: responsesDocument([(200, "{ \(jsonTask) }"), (201, "{ \(jsonTask) }")]),
        controller: tupleController(
            "(status: \(opAStatus), body: String)",
            statusCases: ["ok", "created(\(opAOutput).Created.Headers)"]
        )
    ),
    Gate(
        name: "tuple/headers-as-http-fields",
        summary: "free header fields would let the handler send headers the document does not declare",
        document: responsesDocument([
            (201, "{ \(jsonTask), headers: { Location: { required: true, schema: { type: string } } } }")
        ]),
        controller: tupleController("(headers: HTTPFields, body: String)")
    ),
    Gate(
        name: "tuple/headers-of-another-response",
        summary: "the returned headers are exactly the one success's generated Headers",
        document: responsesDocument([
            (201, "{ \(jsonTask), headers: { Location: { required: true, schema: { type: string } } } }")
        ]),
        controller: tupleController("(headers: \(opAOutput).Ok.Headers, body: String)")
    ),
    Gate(
        name: "tuple/headers-for-a-headerless-response",
        summary: "a response declaring no headers has none to return",
        document: responsesDocument([(200, "{ \(jsonTask) }")]),
        controller: tupleController("(headers: \(opAOutput).Ok.Headers, body: String)")
    ),
    Gate(
        name: "tuple/required-header-not-returned",
        summary: "a required header has to come from somewhere, and a handler returning the body alone has none",
        document: responsesDocument([
            (201, "{ \(jsonTask), headers: { Location: { required: true, schema: { type: string } } } }")
        ]),
        controller: tupleController("String")
    ),
    Gate(
        name: "accepted/status-tuple-over-two-successes",
        summary: "the shape the tuple diagnostics point at: a status chosen among two documented successes",
        document: responsesDocument([
            (200, "{ \(jsonTask), headers: { ETag: { schema: { type: string } } } }"),
            (201, "{ \(jsonTask), headers: { Location: { required: true, schema: { type: string } } } }"),
        ]),
        controller: tupleController(
            "(status: \(opAStatus), body: String)",
            statusCases: ["ok(\(opAOutput).Ok.Headers)", "created(\(opAOutput).Created.Headers)"]
        )
    ),
    Gate(
        name: "accepted/headers-of-any-schema",
        summary: "headers are returned as their generated type, so an integer header needs no conversion",
        document: responsesDocument([
            (200, "{ \(jsonTask), headers: { X-Count: { required: true, schema: { type: integer } } } }")
        ]),
        controller: tupleController("(headers: \(opAOutput).Ok.Headers, body: String)")
    ),
    Gate(
        name: "accepted/headers-of-a-referenced-response",
        summary: "a referenced response's headers are named from its component, as the generator names them",
        document: responsesDocument([(201, "{ $ref: '#/components/responses/Located' }")])
            + "components:\n  responses:\n    Located: { \(jsonTask), headers: { Location: { schema: { type: string } } } }\n",
        controller: tupleController("(headers: Components.Responses.Located.Headers, body: String)")
    ),
    // The one accept case, and it earns its place: it is the arrangement the "disagree" message tells the
    // author to move to. A diagnostic whose advice does not work is worse than no diagnostic.
    Gate(
        name: "accepted/per-operation-forms-are-the-remedy-for-disagreement",
        summary: "each operation takes the form its own documented response requires",
        document: document([("opA", .bodied), ("opB", .bare)]),
        controller: controller(
            operations: [
                ("opA", ["@ErrorResponse(Gone.self, .notFound, \(problemBody))"]),
                ("opB", ["@ErrorResponse(Gone.self, .notFound)"]),
            ]
        )
    ),
]

// MARK: - running one case

/// Run WireOpenAPIGen over a case and report what a caller would see.
///
/// The working directory is the case's own, and every path is relative, so the messages carry
/// `Controller.swift:11:` rather than a path that differs per machine and per checkout.
func run(_ gate: Gate) -> String {
    let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wire-diagnostic-gate-\(ProcessInfo.processInfo.processIdentifier)")
        .appendingPathComponent(gate.name.replacingOccurrences(of: "/", with: "-"))
    try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDirectory) }
    do {
        try gate.document.write(
            to: workDirectory.appendingPathComponent("openapi.yaml"),
            atomically: true,
            encoding: .utf8
        )
        try gate.controller.write(
            to: workDirectory.appendingPathComponent("Controller.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "generate: [types, server]\naccessModifier: internal\nnamingStrategy: idiomatic\n".write(
            to: workDirectory.appendingPathComponent("config.yaml"),
            atomically: true,
            encoding: .utf8
        )
        if let settings = gate.settings {
            try settings.write(
                to: workDirectory.appendingPathComponent("wire-openapi.yaml"),
                atomically: true,
                encoding: .utf8
            )
        }
    } catch { fail("cannot lay out the case '\(gate.name)': \(error)") }

    let process = Process()
    process.executableURL = generatorBinary
    process.currentDirectoryURL = workDirectory
    // The settings flag only when the case wrote the file, so "absent" is exercised as well as "off".
    process.arguments =
        ["out.swift", "--spec", "openapi.yaml", "--spec-config", "config.yaml"]
        + (gate.settings == nil ? [] : ["--spec-settings", "wire-openapi.yaml"])
        + ["--module", "Gate", "Controller.swift"]
    let errors = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    do { try process.run() } catch { fail("cannot run \(generatorBinary.path): \(error)") }
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let message = (String(bytes: errorData, encoding: .utf8) ?? "<unreadable>")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus != 0 else {
        // An accept case is a real outcome, not the absence of one. Anything it wrote to stderr is
        // carried too, so a warning cannot appear unnoticed.
        return message.isEmpty ? "accepted" : "accepted, with output:\n\(message)"
    }
    return "rejected: \(message)"
}

// MARK: - the table

func buildTable() -> String {
    var rows = [
        "# Generated by `swift run DiagnosticGoldenTool` — what WireOpenAPIGen answers each case with.",
        "# `--check` fails if any of these stops firing or changes wording.",
    ]
    for gate in gates {
        rows.append("")
        rows.append("## \(gate.name)")
        rows.append("# \(gate.summary)")
        rows.append(run(gate))
    }
    return rows.joined(separator: "\n") + "\n"
}

let table = buildTable()
if CommandLine.arguments.contains("--check") {
    guard let current = try? String(contentsOf: goldenURL, encoding: .utf8) else {
        fail("cannot read \(goldenURL.path)")
    }
    guard current != table else {
        print("diagnostics match the golden (\(gates.count) cases).")
        exit(0)
    }
    var report = """
        WireOpenAPIGen no longer answers \(goldenURL.lastPathComponent) as recorded.
        A diagnostic that stopped firing is a hole; one that changed wording needs review.

        """
    let currentRows = current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let freshRows = table.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (index, row) in freshRows.enumerated() where index >= currentRows.count || currentRows[index] != row {
        report += "\n  was:   \(index < currentRows.count ? currentRows[index] : "(absent)")\n  now:   \(row)"
    }
    fail(report)
}
do { try table.write(to: goldenURL, atomically: true, encoding: .utf8) } catch {
    fail("cannot write \(goldenURL.path): \(error)")
}
print("wrote \(goldenURL.lastPathComponent) (\(gates.count) cases).")
