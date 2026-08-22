import Foundation

// The checks a generated validator calls, one per assertion the document can make about a scalar.
//
// Emitted code calls these rather than inlining comparisons, for two reasons. The awkward parts —
// counting a string in **code points** rather than grapheme clusters, `multipleOf` on a binary float,
// the nil case — are decided once here instead of once per emission site. And every parameter is passed
// as an `Optional`, which is what lets one call shape serve a required parameter and an optional one
// alike: a non-optional `String` promotes at the call site, so the emitter never has to know which the
// document declared. A `nil` value is not a failure — absence is `required`'s business, and the
// generator already enforced that by making the member non-optional.

/// A `pattern`, compiled once.
///
/// Held as a value rather than a bare `Regex` so the failure can report the expression the document
/// wrote, not the compiled object. The initialiser traps on an unparseable pattern, and that is safe
/// because `WireOpenAPIGen` compiles every pattern at *build* time and refuses to emit one Swift cannot
/// read — so reaching the trap means generated code was hand-edited.
public struct WireOpenAPIPattern: @unchecked Sendable {
    public let source: String
    private let regex: Regex<AnyRegexOutput>

    public init(_ source: String) {
        self.source = source
        guard let regex = try? Regex(source) else {
            preconditionFailure("WireOpenAPI: '\(source)' is not a pattern this runtime can compile.")
        }
        self.regex = regex
    }

    /// JSON Schema's `pattern` is an unanchored **find**, not a whole-string match: a pattern anchors
    /// itself with `^`/`$` when it means to.
    public func matches(_ value: String) -> Bool { value.firstMatch(of: regex) != nil }
}

/// The assertions, grouped by the JSON type they apply to.
public enum WireOpenAPIValidate {
    // MARK: - strings

    public static func string(
        _ value: String?,
        at path: String,
        in location: WireOpenAPIFailureLocation,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        pattern: WireOpenAPIPattern? = nil,
        into failures: inout WireOpenAPIFailureAccumulator
    ) {
        guard let value, !failures.isFull else { return }
        // Code points, not characters. JSON Schema counts the former and `String.count` counts the
        // latter, so a flag emoji is one `Character` and several scalars — a difference that only ever
        // shows up on non-ASCII input, which is exactly when it is hardest to notice.
        let length = value.unicodeScalars.count
        if let minLength, length < minLength {
            failures.record(
                path: path,
                keyword: "minLength",
                expected: "\(minLength)",
                actual: "\(length)",
                location: location
            )
        }
        if let maxLength, length > maxLength {
            failures.record(
                path: path,
                keyword: "maxLength",
                expected: "\(maxLength)",
                actual: "\(length)",
                location: location
            )
        }
        if let pattern, !pattern.matches(value) {
            failures.record(
                path: path,
                keyword: "pattern",
                expected: pattern.source,
                actual: value,
                location: location
            )
        }
    }

    // MARK: - integers

    /// Generic over width because `format` decides it: the generator emits `Int` for a bare
    /// `type: integer`, but `Int32` for `format: int32` and `Int64` for `int64`. One call shape has to
    /// serve all three, or the emitter would have to spell the width and get it wrong the first time a
    /// document used a format nobody tested.
    ///
    /// Compared in `Int64`, which holds every integer type the generator emits without loss.
    public static func integer<T: BinaryInteger>(
        _ value: T?,
        at path: String,
        in location: WireOpenAPIFailureLocation,
        minimum: Int? = nil,
        exclusiveMinimum: Bool = false,
        maximum: Int? = nil,
        exclusiveMaximum: Bool = false,
        multipleOf: Int? = nil,
        into failures: inout WireOpenAPIFailureAccumulator
    ) {
        guard let raw = value, !failures.isFull else { return }
        let value = Int64(raw)
        if let minimum, exclusiveMinimum ? value <= Int64(minimum) : value < Int64(minimum) {
            failures.record(
                path: path,
                keyword: exclusiveMinimum ? "exclusiveMinimum" : "minimum",
                expected: "\(minimum)",
                actual: "\(value)",
                location: location
            )
        }
        if let maximum, exclusiveMaximum ? value >= Int64(maximum) : value > Int64(maximum) {
            failures.record(
                path: path,
                keyword: exclusiveMaximum ? "exclusiveMaximum" : "maximum",
                expected: "\(maximum)",
                actual: "\(value)",
                location: location
            )
        }
        // Exact, because OpenAPIKit gives an integer schema an `Int` `multipleOf`. The tolerance question
        // below belongs only to `type: number`.
        if let multipleOf, multipleOf != 0, value % Int64(multipleOf) != 0 {
            failures.record(
                path: path,
                keyword: "multipleOf",
                expected: "\(multipleOf)",
                actual: "\(value)",
                location: location
            )
        }
    }

    // MARK: - numbers

    /// Generic for the same reason as `integer`: `format: float` emits `Float`, everything else
    /// `Double`. Compared in `Double`, which holds a `Float` exactly.
    public static func number<T: BinaryFloatingPoint>(
        _ value: T?,
        at path: String,
        in location: WireOpenAPIFailureLocation,
        minimum: Double? = nil,
        exclusiveMinimum: Bool = false,
        maximum: Double? = nil,
        exclusiveMaximum: Bool = false,
        multipleOf: Double? = nil,
        into failures: inout WireOpenAPIFailureAccumulator
    ) {
        guard let raw = value, !failures.isFull else { return }
        let value = Double(raw)
        if let minimum, exclusiveMinimum ? value <= minimum : value < minimum {
            failures.record(
                path: path,
                keyword: exclusiveMinimum ? "exclusiveMinimum" : "minimum",
                expected: "\(minimum)",
                actual: "\(value)",
                location: location
            )
        }
        if let maximum, exclusiveMaximum ? value >= maximum : value > maximum {
            failures.record(
                path: path,
                keyword: exclusiveMaximum ? "exclusiveMaximum" : "maximum",
                expected: "\(maximum)",
                actual: "\(value)",
                location: location
            )
        }
        guard let multipleOf, multipleOf != 0 else { return }
        // `0.3` is not representable in binary, so `0.3.truncatingRemainder(dividingBy: 0.1)` is not 0 —
        // it is either a hair above zero or a hair below the divisor. Both ends count as divisible, and
        // the tolerance is relative to the divisor so it scales with the numbers in play. A document
        // wanting exactness should say `type: integer`, where the check above is exact.
        let remainder = abs(value.truncatingRemainder(dividingBy: multipleOf))
        let tolerance = abs(multipleOf) * 1e-9
        if remainder > tolerance, abs(remainder - abs(multipleOf)) > tolerance {
            failures.record(
                path: path,
                keyword: "multipleOf",
                expected: "\(multipleOf)",
                actual: "\(value)",
                location: location
            )
        }
    }

    // MARK: - arrays

    /// The array assertions, and a hook for the element ones.
    ///
    /// The element closure is emitted rather than inlined at the call site because the nil check and the
    /// indexing belong here: the caller would otherwise need to know whether the parameter is optional,
    /// which is the thing this whole shape exists to avoid. Elements are indexed into the path
    /// (`query.tags[2]`), so a failure names the one that failed rather than the collection.
    public static func array<Element: Hashable>(
        _ value: [Element]?,
        at path: String,
        in location: WireOpenAPIFailureLocation,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        uniqueItems: Bool = false,
        into failures: inout WireOpenAPIFailureAccumulator,
        element: (Element, String, inout WireOpenAPIFailureAccumulator) -> Void = { _, _, _ in }
    ) {
        guard let value, !failures.isFull else { return }
        if let minItems, value.count < minItems {
            failures.record(
                path: path,
                keyword: "minItems",
                expected: "\(minItems)",
                actual: "\(value.count)",
                location: location
            )
        }
        if let maxItems, value.count > maxItems {
            failures.record(
                path: path,
                keyword: "maxItems",
                expected: "\(maxItems)",
                actual: "\(value.count)",
                location: location
            )
        }
        // `uniqueItems: true` does not make the generated property a `Set` — it stays an `Array` — so
        // this is a real check rather than one the type system already made.
        if uniqueItems, Set(value).count != value.count {
            failures.record(
                path: path,
                keyword: "uniqueItems",
                expected: "true",
                actual: "\(value.count) items, \(Set(value).count) distinct",
                location: location
            )
        }
        for (index, item) in value.enumerated() {
            guard !failures.isFull else { return }
            element(item, "\(path)[\(index)]", &failures)
        }
    }
}
