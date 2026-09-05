// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-open-api project authors

import Foundation
import SwiftParser
import SwiftSyntax

// Regenerates (or checks) the naming golden table from the *real* swift-openapi-generator.
//
// `WireOpenAPINaming` transcribes the generator's internal `SafeNameGenerator`, which the typed shim
// needs to name generated symbols. A copied algorithm does not fail when it is wrong today — it fails
// when the original changes and ours does not, and the symptom is "cannot find type `Operations.Foo`"
// inside generated code.
//
// So the table this writes is produced by running the generator itself: a corpus document whose
// operationIds and parameter names cover the interesting shapes, generated under both naming strategies,
// with the names it actually emitted read back out. `WireOpenAPINamingTests` asserts the transcription
// reproduces this table; CI runs this tool with `--check`, so a generator bump that changes naming fails
// with a name-by-name diff.
//
//     swift run NamingGoldenTool            # rewrite the table
//     swift run NamingGoldenTool --check    # fail if the generator no longer agrees with it
//
// The generator is run as a subprocess rather than linked: depending on it would pull the generator and
// OpenAPIKit into this package's resolution for the sake of one check.

// MARK: - locations

/// Derived from `#filePath` rather than the working directory, so the tool behaves the same however it
/// is invoked. `Sources/NamingGoldenTool/main.swift` → up three.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let testsDirectory = repoRoot.appendingPathComponent("Tests/WireOpenAPINamingTests")
let goldenURL = testsDirectory.appendingPathComponent("naming-golden.tsv")
let statusGoldenURL = testsDirectory.appendingPathComponent("status-golden.tsv")
let corpusURL = testsDirectory.appendingPathComponent("naming-corpus.txt")
let generatorPath =
    ProcessInfo.processInfo.environment["OPENAPI_GENERATOR_PATH"]
    ?? repoRoot.appendingPathComponent("Fixtures/.build/checkouts/swift-openapi-generator").path

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - the corpus

/// The documented names under test, used both as operationIds and as parameter names.
let corpus: [String] = {
    guard let contents = try? String(contentsOf: corpusURL, encoding: .utf8) else {
        fail("cannot read \(corpusURL.path)")
    }
    return contents.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}()

/// A document with one operation per corpus name (for type names) and one path parameter per name (for
/// member names). A parameter name goes in the path template, so names containing `{`, `}` or `/` cannot
/// appear in that position; they are still exercised as operationIds.
func writeDocument(to url: URL) -> [Int] {
    var lines = ["openapi: 3.1.0", "info: { title: Naming, version: 1.0.0 }", "paths:"]
    for (index, name) in corpus.enumerated() {
        lines.append(
            """
              /op\(index):
                get:
                  operationId: '\(name)'
                  responses: { '200': { description: ok } }
            """
        )
    }
    var parameterised: [Int] = []
    for (index, name) in corpus.enumerated() where !name.contains(where: { "{}/".contains($0) }) {
        parameterised.append(index)
        lines.append(
            """
              /p\(index)/{\(name)}:
                get:
                  operationId: param\(index)
                  parameters:
                    - name: '\(name)'
                      in: path
                      required: true
                      schema: { type: string }
                  responses: { '200': { description: ok } }
            """
        )
    }
    do { try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) } catch {
        fail("cannot write the corpus document: \(error)")
    }
    return parameterised
}

// MARK: - running the generator

func runGenerator(document: URL, strategy: String, workDirectory: URL) -> String {
    let config = workDirectory.appendingPathComponent("config-\(strategy).yaml")
    let output = workDirectory.appendingPathComponent("out-\(strategy)")
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    do {
        try """
        generate:
          - types
        accessModifier: internal
        namingStrategy: \(strategy)

        """.write(to: config, atomically: true, encoding: .utf8)
    } catch { fail("cannot write the generator config: \(error)") }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift", "run", "--package-path", generatorPath, "swift-openapi-generator", "generate",
        "--config", config.path, "--output-directory", output.path, document.path,
    ]
    let errors = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    do { try process.run() } catch { fail("cannot run the generator at \(generatorPath): \(error)") }
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(bytes: errorData, encoding: .utf8) ?? "<unreadable>"
        fail("the generator failed for \(strategy):\n\(message.suffix(2000))")
    }
    let types = output.appendingPathComponent("Types.swift")
    guard let contents = try? String(contentsOf: types, encoding: .utf8) else {
        fail("the generator produced no Types.swift for \(strategy)")
    }
    return contents
}

// MARK: - reading the names back

/// The first stored property of a `Path` struct nested anywhere under a node.
final class PathMemberFinder: SyntaxVisitor {
    private(set) var member: String?

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.name.text == "Path" else { return .visitChildren }
        for item in node.memberBlock.members {
            guard let variable = item.decl.as(VariableDeclSyntax.self),
                let binding = variable.bindings.first,
                let identifier = binding.pattern.as(IdentifierPatternSyntax.self)
            else { continue }
            member = identifier.identifier.text
            break
        }
        return .skipChildren
    }
}

/// What the generator emitted: documented operationId → its `Operations` namespace, and the same enum's
/// path member when it has one.
///
/// Keyed off the generated `static let id`, which holds the operationId verbatim — more robust than
/// reading the doc comments, and it is the same value the generator hands `forOperation:`.
func extractNames(from source: String) -> (types: [String: String], members: [String: String]) {
    var types: [String: String] = [:]
    var members: [String: String] = [:]
    let tree = Parser.parse(source: source)
    for statement in tree.statements {
        guard let operations = statement.item.as(EnumDeclSyntax.self), operations.name.text == "Operations"
        else { continue }
        for item in operations.memberBlock.members {
            guard let operation = item.decl.as(EnumDeclSyntax.self) else { continue }
            var documented: String?
            for member in operation.memberBlock.members {
                guard let variable = member.decl.as(VariableDeclSyntax.self),
                    let binding = variable.bindings.first,
                    binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "id",
                    let literal = binding.initializer?.value.as(StringLiteralExprSyntax.self)
                else { continue }
                documented = literal.representedLiteralValue
            }
            guard let documented else { continue }
            types[documented] = operation.name.text
            let finder = PathMemberFinder(viewMode: .sourceAccurate)
            finder.walk(operation)
            if let member = finder.member { members[documented] = member }
        }
    }
    return (types, members)
}

// MARK: - the status table

/// A document declaring one operation per status code, so the `Output` case the generator names for each
/// can be read back. The range is exhaustive rather than sampled: a status the generator learns to name,
/// or renames, then fails CI without anyone having to think of it.
func writeStatusDocument(to url: URL) -> [Int] {
    let codes = Array(100...599)
    var lines = ["openapi: 3.1.0", "info: { title: Statuses, version: 1.0.0 }", "paths:"]
    for code in codes {
        lines.append(
            """
              /s\(code):
                get:
                  operationId: status\(code)
                  responses:
                    '\(code)': { description: a response }
            """
        )
    }
    do { try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) } catch {
        fail("cannot write the status document: \(error)")
    }
    return codes
}

/// operationId → the one `Output` case that is not `undocumented`.
func extractStatusCases(from source: String) -> [String: String] {
    var found: [String: String] = [:]
    let tree = Parser.parse(source: source)
    for statement in tree.statements {
        guard let operations = statement.item.as(EnumDeclSyntax.self), operations.name.text == "Operations"
        else { continue }
        for item in operations.memberBlock.members {
            guard let operation = item.decl.as(EnumDeclSyntax.self) else { continue }
            guard let documented = operationID(of: operation), let caseName = outputCase(of: operation)
            else { continue }
            found[documented] = caseName
        }
    }
    return found
}

/// The `static let id` an operation enum carries: its operationId, verbatim.
func operationID(of operation: EnumDeclSyntax) -> String? {
    for member in operation.memberBlock.members {
        guard let variable = member.decl.as(VariableDeclSyntax.self),
            let binding = variable.bindings.first,
            binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "id",
            let literal = binding.initializer?.value.as(StringLiteralExprSyntax.self)
        else { continue }
        return literal.representedLiteralValue
    }
    return nil
}

/// The one `Output` case that is not `undocumented`.
///
/// `trimmedDescription`, not `.text`: the generator backticks a case whose name is a keyword
/// (`` `continue` `` for 100), and the backticks are part of what it emitted.
func outputCase(of operation: EnumDeclSyntax) -> String? {
    for member in operation.memberBlock.members {
        guard let output = member.decl.as(EnumDeclSyntax.self), output.name.text == "Output" else { continue }
        for outputMember in output.memberBlock.members {
            guard let caseDecl = outputMember.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements where element.name.text != "undocumented" {
                return element.name.trimmedDescription
            }
        }
    }
    return nil
}

func buildStatusTable() -> String {
    let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wire-status-golden-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDirectory) }
    let document = workDirectory.appendingPathComponent("openapi.yaml")
    let codes = writeStatusDocument(to: document)
    let cases = extractStatusCases(
        from: runGenerator(document: document, strategy: "idiomatic", workDirectory: workDirectory)
    )
    var rows = [
        "# status\toutput case",
        "# Generated by `swift run NamingGoldenTool` from the real swift-openapi-generator.",
    ]
    for code in codes {
        guard let name = cases["status\(code)"] else {
            fail("the generator emitted no Output case for status \(code)")
        }
        rows.append("\(code)\t\(name)")
    }
    return rows.joined(separator: "\n") + "\n"
}

// MARK: - the table

func buildTable() -> String {
    let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wire-naming-golden-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDirectory) }

    let document = workDirectory.appendingPathComponent("openapi.yaml")
    let parameterised = Set(writeDocument(to: document))

    var byStrategy: [String: (types: [String: String], members: [String: String])] = [:]
    for strategy in ["defensive", "idiomatic"] {
        byStrategy[strategy] = extractNames(
            from: runGenerator(document: document, strategy: strategy, workDirectory: workDirectory)
        )
    }

    var rows = [
        "# documented\tdefensive.type\tdefensive.member\tidiomatic.type\tidiomatic.member",
        "# Generated by `swift run NamingGoldenTool` from the real swift-openapi-generator.",
        "# '-' means the shape cannot appear in that position (parameters live in a path template).",
    ]
    for (index, name) in corpus.enumerated() {
        guard let defensive = byStrategy["defensive"], let idiomatic = byStrategy["idiomatic"],
            let defensiveType = defensive.types[name], let idiomaticType = idiomatic.types[name]
        else { fail("the generator produced no type name for '\(name)'; corpus or extraction is wrong") }
        // The parameter operations are named `param<i>`, which is how a member is tied back to its name.
        let parameterID = "param\(index)"
        let defensiveMember = parameterised.contains(index) ? defensive.members[parameterID] ?? "-" : "-"
        let idiomaticMember = parameterised.contains(index) ? idiomatic.members[parameterID] ?? "-" : "-"
        rows.append(
            [name, defensiveType, defensiveMember, idiomaticType, idiomaticMember].joined(separator: "\t")
        )
    }
    return rows.joined(separator: "\n") + "\n"
}

// MARK: - main

/// Both tables, each against its own file.
func compare(_ fresh: String, with url: URL, label: String) -> String? {
    guard let current = try? String(contentsOf: url, encoding: .utf8) else {
        return "cannot read \(url.path)"
    }
    guard current != fresh else { return nil }
    var report = """
        The generator no longer agrees with \(url.lastPathComponent).
        Sources/WireOpenAPINaming transcribes its \(label); it has diverged.

        """
    let currentRows = current.split(separator: "\n").map(String.init)
    let freshRows = fresh.split(separator: "\n").map(String.init)
    for (index, row) in freshRows.enumerated() where index >= currentRows.count || currentRows[index] != row {
        report += "\n  was:   \(index < currentRows.count ? currentRows[index] : "(absent)")\n  now:   \(row)"
    }
    return report
}

let table = buildTable()
let statusTable = buildStatusTable()
if CommandLine.arguments.contains("--check") {
    let reports = [
        compare(table, with: goldenURL, label: "safe-name transform"),
        compare(statusTable, with: statusGoldenURL, label: "status-code table"),
    ].compactMap { $0 }
    guard reports.isEmpty else { fail(reports.joined(separator: "\n\n")) }
    print("golden tables match the generator (\(corpus.count) names, 500 statuses).")
    exit(0)
}
do {
    try table.write(to: goldenURL, atomically: true, encoding: .utf8)
    try statusTable.write(to: statusGoldenURL, atomically: true, encoding: .utf8)
} catch { fail("cannot write the golden tables: \(error)") }
print("wrote \(goldenURL.lastPathComponent) (\(corpus.count) names) and \(statusGoldenURL.lastPathComponent).")
