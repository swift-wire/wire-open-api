// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireOpenAPI

/// The checks a generated validator calls. What is worth asserting is the handful of places where the
/// obvious implementation is wrong: counting a string, dividing a float, and deciding that absence is
/// not a failure.
@Suite("Validation checks")
struct ValidationChecksTests {
    private func collect(
        _ body: (inout WireOpenAPIFailureAccumulator) -> Void
    ) -> [WireOpenAPIFailure] {
        var accumulator = WireOpenAPIFailureAccumulator()
        body(&accumulator)
        return accumulator.failures
    }

    /// Absence is `required`'s business, and the generator already enforced it by making the member
    /// non-optional. A validator that treated nil as a failure would reject every optional parameter.
    @Test("nil is never a failure")
    func nilPasses() {
        let failures = collect {
            WireOpenAPIValidate.string(nil, at: "query.q", in: .query, minLength: 5, into: &$0)
            WireOpenAPIValidate.integer(Int?.none, at: "query.n", in: .query, minimum: 5, into: &$0)
            WireOpenAPIValidate.array([String]?.none, at: "query.a", in: .query, minItems: 1, into: &$0)
        }
        #expect(failures.isEmpty)
    }

    /// JSON Schema counts **code points**; `String.count` counts grapheme clusters. A family emoji is one
    /// Character and several scalars, so the two disagree exactly where nobody is looking.
    @Test("length is counted in code points, not characters")
    func lengthCountsScalars() {
        let flag = "🇦🇺"  // one Character, two scalars
        #expect(flag.count == 1 && flag.unicodeScalars.count == 2)
        // maxLength 1 must reject it: two code points exceed one.
        let failures = collect {
            WireOpenAPIValidate.string(flag, at: "query.q", in: .query, maxLength: 1, into: &$0)
        }
        #expect(failures.map(\.keyword) == ["maxLength"])
        #expect(failures.first?.actual == "2")
    }

    @Test("pattern is an unanchored find, as JSON Schema specifies")
    func patternIsAFind() {
        // Unanchored: `[0-9]+` is satisfied by a digit anywhere, not only by an all-digit string.
        let unanchored = collect {
            WireOpenAPIValidate.string(
                "abc123",
                at: "query.q",
                in: .query,
                pattern: WireOpenAPIPattern("[0-9]+"),
                into: &$0
            )
        }
        #expect(unanchored.isEmpty)
        // A pattern that anchors itself still anchors.
        let anchored = collect {
            WireOpenAPIValidate.string(
                "abc123",
                at: "query.q",
                in: .query,
                pattern: WireOpenAPIPattern("^[0-9]+$"),
                into: &$0
            )
        }
        #expect(anchored.map(\.keyword) == ["pattern"])
    }

    /// The bound is inclusive unless the document says otherwise, and the reported keyword has to say
    /// which — a caller told "minimum: 0" when the document said `exclusiveMinimum: 0` would resubmit 0.
    @Test("exclusive bounds exclude, and name themselves")
    func exclusiveBounds() {
        let inclusive = collect {
            WireOpenAPIValidate.integer(0, at: "q.n", in: .query, minimum: 0, into: &$0)
        }
        #expect(inclusive.isEmpty)
        let exclusive = collect {
            WireOpenAPIValidate.integer(
                0,
                at: "q.n",
                in: .query,
                minimum: 0,
                exclusiveMinimum: true,
                into: &$0
            )
        }
        #expect(exclusive.map(\.keyword) == ["exclusiveMinimum"])
    }

    /// `format` decides the Swift width — `int32` emits `Int32`, `float` emits `Float` — so one call
    /// shape has to serve them all.
    @Test("the numeric checks accept every width the generator emits")
    func widthsAreAccepted() {
        let failures = collect {
            WireOpenAPIValidate.integer(Int32(5), at: "a", in: .query, maximum: 4, into: &$0)
            WireOpenAPIValidate.integer(Int64(5), at: "b", in: .query, maximum: 4, into: &$0)
            WireOpenAPIValidate.number(Float(5), at: "c", in: .query, maximum: 4, into: &$0)
        }
        #expect(failures.count == 3)
    }

    /// `0.3` is not representable in binary, so the naive remainder check calls it not-a-multiple of
    /// `0.1`. The tolerance exists for exactly this, and it must not be so loose that a real violation
    /// slips through.
    @Test("multipleOf survives binary floating point, without going blind")
    func multipleOfTolerance() {
        let representable = collect {
            WireOpenAPIValidate.number(0.3, at: "q", in: .query, multipleOf: 0.1, into: &$0)
        }
        #expect(representable.isEmpty)
        let violating = collect {
            WireOpenAPIValidate.number(0.25, at: "q", in: .query, multipleOf: 0.1, into: &$0)
        }
        #expect(violating.map(\.keyword) == ["multipleOf"])
        // Integers are exact — no tolerance involved.
        let exact = collect {
            WireOpenAPIValidate.integer(7, at: "q", in: .query, multipleOf: 5, into: &$0)
        }
        #expect(exact.map(\.keyword) == ["multipleOf"])
    }

    /// `uniqueItems: true` does not make the generated property a `Set` — it stays an `Array` — so this
    /// is a real check rather than one the type system already made.
    @Test("uniqueItems is checked, because the generated type is still an Array")
    func uniqueItems() {
        let failures = collect {
            WireOpenAPIValidate.array(
                ["a", "b", "a"],
                at: "query.tags",
                in: .query,
                uniqueItems: true,
                into: &$0
            )
        }
        #expect(failures.map(\.keyword) == ["uniqueItems"])
    }

    /// A failing element names itself by index. Reporting the collection would tell the caller which
    /// parameter to look at and leave them to find which value.
    @Test("an element failure carries its index")
    func elementPathsAreIndexed() {
        let failures = collect { accumulator in
            WireOpenAPIValidate.array(
                ["ok", "x", "fine"],
                at: "query.tags",
                in: .query,
                into: &accumulator,
                element: { item, path, failures in
                    WireOpenAPIValidate.string(item, at: path, in: .query, minLength: 2, into: &failures)
                }
            )
        }
        #expect(failures.map(\.path) == ["query.tags[1]"])
    }

    /// Every failure in one pass, which is the whole reason for the accumulator.
    @Test("one value can fail several assertions at once")
    func severalAtOnce() {
        let failures = collect {
            WireOpenAPIValidate.string(
                "X",
                at: "query.q",
                in: .query,
                minLength: 3,
                pattern: WireOpenAPIPattern("^[a-z]+$"),
                into: &$0
            )
        }
        #expect(failures.map(\.keyword) == ["minLength", "pattern"])
        #expect(failures.allSatisfy { $0.path == "query.q" })
    }
}
