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
func controller(
    typeAttributes: [String] = [],
    operations: [(id: String, attributes: [String])]
) -> String {
    var lines = [
        "import Wire", "import WireOpenAPI", "", "struct Gone: Error {}", "",
        "@Singleton", "@OpenAPIController",
    ]
    lines += typeAttributes
    lines.append("struct GateController {")
    for (id, attributes) in operations {
        lines.append("    @Operation")
        lines += attributes.map { "    " + $0 }
        lines.append("    func \(id)() async throws { throw Gone() }")
        lines.append("")
    }
    lines.append("}")
    return lines.joined(separator: "\n") + "\n"
}

let problemBody = #"{ _ in Components.Schemas.Problem(message: "x") }"#

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

struct Gate {
    let name: String
    /// Why this case exists, carried into the golden so a reader of the table knows what it protects.
    let summary: String
    let document: String
    let controller: String
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
    } catch { fail("cannot lay out the case '\(gate.name)': \(error)") }

    let process = Process()
    process.executableURL = generatorBinary
    process.currentDirectoryURL = workDirectory
    process.arguments = [
        "out.swift", "--spec", "openapi.yaml", "--spec-config", "config.yaml",
        "--module", "Gate", "Controller.swift",
    ]
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
