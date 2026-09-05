// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-open-api project authors

import Foundation
import Testing

@testable import WireOpenAPINaming

/// Holds the transcribed transform to what swift-openapi-generator actually emits.
///
/// `naming-golden.tsv` is not hand-written: `swift run NamingGoldenTool` produces it by running the real
/// generator over `naming-corpus.txt` under both naming strategies and reading back the names it emitted.
/// So this asserts *our copy reproduces the generator*, rather than asserting our copy matches our own
/// expectations — which is the only version of this test worth having, since the failure a copy invites is
/// divergence from the original, not disagreement with ourselves.
///
/// The other half lives in CI, which runs the tool with `--check`: this catches a regression in the
/// transcription, that step catches the generator changing underneath it.
@Suite("Generator safe names")
struct GeneratorSafeNamesTests {
    /// One documented name and the four names the generator makes of it.
    struct Row: Sendable, CustomTestStringConvertible {
        let documented: String
        let defensiveType: String
        let defensiveMember: String?
        let idiomaticType: String
        let idiomaticMember: String?

        /// The documented name identifies the case in test output, so a failure reads as the name that
        /// broke rather than as an index.
        var testDescription: String { documented.debugDescription }
    }

    /// Parsed once. A read failure yields no rows rather than trapping during collection, and
    /// `theGoldenTableLoaded` is what reports it.
    static let golden: [Row] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("naming-golden.tsv")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n").compactMap { line -> Row? in
            guard !line.hasPrefix("#") else { return nil }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == 5 else { return nil }
            return Row(
                documented: columns[0],
                defensiveType: columns[1],
                defensiveMember: columns[2] == "-" ? nil : columns[2],
                idiomaticType: columns[3],
                idiomaticMember: columns[4] == "-" ? nil : columns[4]
            )
        }
    }()

    @Test("the golden table loaded")
    func theGoldenTableLoaded() {
        #expect(Self.golden.count > 40, "naming-golden.tsv is missing or truncated")
    }

    /// One case per documented name, so a divergence names the inputs it hit rather than reporting a
    /// single opaque failure — and a rule that moves shows up as a cluster of related names.
    @Test("the transcription reproduces the generator", arguments: GeneratorSafeNamesTests.golden)
    func reproducesTheGenerator(_ row: Row) {
        #expect(
            GeneratorSafeNames.swiftTypeName(for: row.documented, strategy: .defensive) == row.defensiveType
        )
        #expect(
            GeneratorSafeNames.swiftTypeName(for: row.documented, strategy: .idiomatic) == row.idiomaticType
        )
        if let expected = row.defensiveMember {
            #expect(
                GeneratorSafeNames.swiftMemberName(for: row.documented, strategy: .defensive) == expected
            )
        }
        if let expected = row.idiomaticMember {
            #expect(
                GeneratorSafeNames.swiftMemberName(for: row.documented, strategy: .idiomatic) == expected
            )
        }
    }

    /// Every status the generator can name, read back from it.
    static let statusGolden: [(code: Int, caseName: String)] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("status-golden.tsv")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let columns = line.split(separator: "\t").map(String.init)
            guard columns.count == 2, let code = Int(columns[0]) else { return nil }
            return (code, columns[1])
        }
    }()

    @Test("the status table covers every code the generator names")
    func statusTableLoaded() {
        #expect(Self.statusGolden.count == 500, "status-golden.tsv should cover 100...599")
    }

    /// The status table is pure data, so this is a straight comparison — but it is comparison against
    /// what the generator emitted, not against a list someone typed twice.
    @Test("the status table reproduces the generator", arguments: GeneratorSafeNamesTests.statusGolden)
    func statusCaseMatchesTheGenerator(_ row: (code: Int, caseName: String)) {
        #expect(GeneratorStatusNames.safeName(for: row.code) == row.caseName)
    }

    /// The default is easy to get wrong: a document that says nothing about `namingStrategy` is
    /// **defensive**, not idiomatic, so a shim that assumed idiomatic would misname every symbol in the
    /// most common configuration of all — the one nobody configured.
    @Test("the generator's default strategy is defensive")
    func generatorDefaultIsDefensive() {
        #expect(GeneratorNamingStrategy.generatorDefault == .defensive)
    }

    /// The two cases the shim leans on hardest, spelled out so a reader sees the shape without decoding
    /// the table.
    @Test("the cases the shim depends on")
    func theCasesTheShimDependsOn() {
        // An operationId becomes an `Operations.<X>` namespace...
        #expect(GeneratorSafeNames.swiftTypeName(for: "getTask", strategy: .idiomatic) == "GetTask")
        #expect(GeneratorSafeNames.swiftTypeName(for: "getTask", strategy: .defensive) == "getTask")
        // ...and a parameter name becomes an `input.path.<y>` member. Header names are why this cannot be
        // skipped: hyphens are conventional there, and neither strategy leaves them alone.
        #expect(GeneratorSafeNames.swiftMemberName(for: "X-Request-Id", strategy: .idiomatic) == "xRequestId")
        #expect(
            GeneratorSafeNames.swiftMemberName(for: "X-Request-Id", strategy: .defensive)
                == "X_hyphen_Request_hyphen_Id"
        )
    }
}
