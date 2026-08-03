import XCTest

@testable import WireOpenAPINaming

/// Holds the transcribed transform to what swift-openapi-generator actually emits.
///
/// `naming-golden.tsv` is not hand-written: `Scripts/refresh-naming-golden.py` produces it by running the
/// real generator over `naming-corpus.txt` under both naming strategies and reading back the names it
/// emitted. So this test asserts *our copy reproduces the generator*, rather than asserting our copy
/// matches our own expectations — which is the only version of this test worth having, since the failure
/// a copy invites is divergence from the original, not disagreement with ourselves.
///
/// The other half of the check lives in CI, which runs the script with `--check`: this test catches a
/// regression in the transcription, that step catches the generator changing underneath it.
final class GeneratorSafeNamesTests: XCTestCase {
    struct Row {
        let documented: String
        let defensiveType: String
        let defensiveMember: String?
        let idiomaticType: String
        let idiomaticMember: String?
    }

    static func loadGolden() throws -> [Row] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("naming-golden.tsv")
        let contents = try String(contentsOf: url, encoding: .utf8)
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
    }

    func testMatchesTheGenerator() throws {
        let rows = try Self.loadGolden()
        XCTAssertGreaterThan(rows.count, 40, "the corpus looks truncated")

        // Collected rather than asserted one at a time: a divergence usually hits a whole class of names,
        // and seeing all of them at once says which rule moved.
        var mismatches: [String] = []
        func check(_ documented: String, _ label: String, _ expected: String, _ actual: String) {
            guard expected != actual else { return }
            mismatches.append("  \(documented.debugDescription) \(label): generator \(expected), ours \(actual)")
        }
        for row in rows {
            check(
                row.documented,
                "defensive.type",
                row.defensiveType,
                GeneratorSafeNames.swiftTypeName(for: row.documented, strategy: .defensive)
            )
            check(
                row.documented,
                "idiomatic.type",
                row.idiomaticType,
                GeneratorSafeNames.swiftTypeName(for: row.documented, strategy: .idiomatic)
            )
            if let expected = row.defensiveMember {
                check(
                    row.documented,
                    "defensive.member",
                    expected,
                    GeneratorSafeNames.swiftMemberName(for: row.documented, strategy: .defensive)
                )
            }
            if let expected = row.idiomaticMember {
                check(
                    row.documented,
                    "idiomatic.member",
                    expected,
                    GeneratorSafeNames.swiftMemberName(for: row.documented, strategy: .idiomatic)
                )
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "the transcription no longer matches the generator:\n" + mismatches.joined(separator: "\n")
        )
    }

    /// The default is easy to get wrong: a document that says nothing about `namingStrategy` is
    /// **defensive**, not idiomatic, so a shim that assumed idiomatic would misname every symbol in the
    /// most common configuration of all — the one nobody configured.
    func testGeneratorDefaultIsDefensive() {
        XCTAssertEqual(GeneratorNamingStrategy.generatorDefault, .defensive)
    }

    /// The two cases the shim will lean on hardest, spelled out so a reader sees the shape without
    /// decoding the table.
    func testTheCasesTheShimDependsOn() {
        // An operationId becomes an `Operations.<X>` namespace...
        XCTAssertEqual(GeneratorSafeNames.swiftTypeName(for: "getTask", strategy: .idiomatic), "GetTask")
        XCTAssertEqual(GeneratorSafeNames.swiftTypeName(for: "getTask", strategy: .defensive), "getTask")
        // ...and a parameter name becomes an `input.path.<y>` member. Header names are the reason this
        // cannot be skipped: hyphens are conventional there, and neither strategy leaves them alone.
        XCTAssertEqual(
            GeneratorSafeNames.swiftMemberName(for: "X-Request-Id", strategy: .idiomatic),
            "xRequestId"
        )
        XCTAssertEqual(
            GeneratorSafeNames.swiftMemberName(for: "X-Request-Id", strategy: .defensive),
            "X_hyphen_Request_hyphen_Id"
        )
    }
}
