// swift-format-ignore-file
//
// Excluded from swift-format and SwiftLint (see .swiftlint.yml). This file is a transcription of
// upstream's `SafeNameGenerator.swift`, and its whole value is that a future upstream diff is readable —
// so it keeps upstream's formatting, its `_state` name, its 109-line state machine and its complexity of
// 28, none of which would survive being brought in line with this package's own rules.

import Foundation

// ┌───────────────────────────────────────────────────────────────────────────────────────────────┐
// │ COPIED LOGIC — do not edit to taste.                                                          │
// │                                                                                               │
// │ A transcription of swift-openapi-generator's `SafeNameGenerator.swift`                        │
// │ (`Sources/_OpenAPIGeneratorCore/Translator/TypeAssignment/SafeNameGenerator.swift`).          │
// │ Structure, control flow and comments are kept as close to the original as Swift allows, so a  │
// │ future upstream diff is readable. Improving it locally would make that diff useless.          │
// └───────────────────────────────────────────────────────────────────────────────────────────────┘
//
// **Why a copy.** The typed shim (M6d.4) has to *name* generated symbols — `Operations.GetTask.Input`,
// `input.path.userId` — rather than copy spellings the author already wrote, which is what every earlier
// milestone did. Those names come from this transform, applied to the document's operationIds and
// parameter names. It is `internal` to `_OpenAPIGeneratorCore`: `NamingStrategy` is public but is only a
// two-case enum naming *which* strategy, carrying none of the behaviour, so there is nothing to call.
//
// **The risk this carries, and the mitigation.** A copied algorithm does not fail when it is wrong today;
// it fails when the original changes and ours does not, and the symptom is "cannot find type
// `Operations.Foo`" inside generated code. So the check that matters is not a unit test of our
// expectations — it is `Scripts/refresh-naming-golden.sh`, which runs the *real generator* over a corpus
// document, extracts the names it actually produced, and diffs them against `naming-golden.tsv`. CI runs
// it. A generator bump that changes naming therefore fails with a name-by-name diff.
//
// **Revisit when productionising.** Three exits, in preference order: upstream exposes a supported naming
// API (ask made, not assumed); or we narrow to a validate-and-reject predicate covering the identity
// cases and rejecting the rest toward `@RawOperation`; or this stays, pinned and golden-tested.
//
// Transcribed from the fork at `tachyonics/swift-openapi-generator@swift-wire`, itself
// swift-openapi-generator 1.x. Not covered here: `swiftContentTypeName`, which the shim will need for
// non-JSON bodies — the first slice restricts itself to JSON.

/// Which naming strategy a document is generated with, read from `openapi-generator-config.yaml`.
public enum GeneratorNamingStrategy: String, Sendable, CaseIterable {
    case defensive
    case idiomatic

    /// The generator's own default when the config omits `namingStrategy`, mirroring
    /// `Config.defaultNamingStrategy`. It is **defensive**, which is easy to forget: a document that
    /// simply does not mention a strategy is not idiomatic.
    public static let generatorDefault: GeneratorNamingStrategy = .defensive
}

/// The two names the shim needs for any documented name.
public enum GeneratorSafeNames {
    /// A name usable as a Swift *type* — how an operationId becomes an `Operations.<X>` namespace.
    public static func swiftTypeName(for documentedName: String, strategy: GeneratorNamingStrategy) -> String {
        switch strategy {
        case .defensive: return defensiveSwiftName(for: documentedName)
        case .idiomatic: return idiomaticSwiftName(for: documentedName, capitalize: true)
        }
    }

    /// A name usable as a Swift *member* — how a spec parameter name becomes `input.path.<y>`.
    public static func swiftMemberName(for documentedName: String, strategy: GeneratorNamingStrategy) -> String {
        switch strategy {
        case .defensive: return defensiveSwiftName(for: documentedName)
        case .idiomatic: return idiomaticSwiftName(for: documentedName, capitalize: false)
        }
    }

    // MARK: - defensive (SOAR-0001)

    /// Replaces characters that are illegal in a Swift identifier with their HTML entity name, or a
    /// unicode hex escape when the map has none, delimited by `_`; ensures the name does not start with
    /// a number; and prefixes Swift keywords.
    static func defensiveSwiftName(for documentedName: String) -> String {
        guard !documentedName.isEmpty else { return "_empty" }

        let firstCharSet: CharacterSet = .letters.union(.init(charactersIn: "_"))
        let numbers: CharacterSet = .decimalDigits
        let otherCharSet: CharacterSet = .alphanumerics.union(.init(charactersIn: "_"))

        var sanitizedScalars: [Unicode.Scalar] = []
        for (index, scalar) in documentedName.unicodeScalars.enumerated() {
            let allowedSet = index == 0 ? firstCharSet : otherCharSet
            let outScalar: Unicode.Scalar
            if allowedSet.contains(scalar) {
                outScalar = scalar
            } else if index == 0 && numbers.contains(scalar) {
                sanitizedScalars.append("_")
                outScalar = scalar
            } else {
                sanitizedScalars.append("_")
                if let entityName = specialCharsMap[scalar] {
                    for char in entityName.unicodeScalars { sanitizedScalars.append(char) }
                } else {
                    sanitizedScalars.append("x")
                    let hexString = String(scalar.value, radix: 16, uppercase: true)
                    for char in hexString.unicodeScalars { sanitizedScalars.append(char) }
                }
                sanitizedScalars.append("_")
                continue
            }
            sanitizedScalars.append(outScalar)
        }

        let validString = String(String.UnicodeScalarView(sanitizedScalars))

        // Special case for a single underscore. It can't go in the map, being a valid identifier
        // elsewhere.
        if validString == "_" { return "_underscore_" }

        guard keywords.contains(validString) else { return validString }
        return "_\(validString)"
    }

    // MARK: - idiomatic (SOAR-0013)

    /// Produces UpperCamelCase or lowerCamelCase, falling back to the defensive strategy for anything
    /// containing characters it cannot handle.
    static func idiomaticSwiftName(for documentedName: String, capitalize: Bool) -> String {
        if documentedName.isEmpty { return capitalize ? "_Empty_" : "_empty_" }

        // Detect cases like HELLO_WORLD, sometimes used for constants. Must check that no characters are
        // lowercased, as non-letter characters don't return `true` to `isUppercase`.
        let isAllUppercase = documentedName.allSatisfy { !$0.isLowercase }

        // 1. Leave leading underscores as-are
        // 2. In the middle: word separators: ["_", "-", "/", "+", <space>] -> remove and capitalize
        //    next word
        // 3. In the middle: period: ["."] -> replace with "_"
        // 4. In the middle: drop ["{", "}"] -> replace with ""
        var buffer: [Character] = []
        buffer.reserveCapacity(documentedName.count)
        enum State: Equatable {
            case modifying
            case preFirstWord
            struct AccumulatingFirstWordContext: Equatable { var isAccumulatingInitialUppercase: Bool }
            case accumulatingFirstWord(AccumulatingFirstWordContext)
            case accumulatingWord
            case waitingForWordStarter
        }
        var state: State = .preFirstWord
        for index in documentedName[...].indices {
            let char = documentedName[index]
            let _state = state
            state = .modifying
            switch _state {
            case .preFirstWord:
                if char == "_" {
                    // Leading underscores are kept.
                    buffer.append(char)
                    state = .preFirstWord
                } else if char.isNumber {
                    // The underscore will be added by the defensive strategy.
                    buffer.append(char)
                    state = .accumulatingFirstWord(.init(isAccumulatingInitialUppercase: false))
                } else if char.isLetter {
                    // First character in the identifier.
                    buffer.append(contentsOf: capitalize ? char.uppercased() : char.lowercased())
                    state = .accumulatingFirstWord(
                        .init(isAccumulatingInitialUppercase: !capitalize && char.isUppercase)
                    )
                } else {
                    // Illegal character, keep and let the defensive strategy deal with it.
                    state = .accumulatingFirstWord(.init(isAccumulatingInitialUppercase: false))
                    buffer.append(char)
                }
            case .accumulatingFirstWord(var context):
                if char.isLetter || char.isNumber {
                    if isAllUppercase {
                        buffer.append(contentsOf: char.lowercased())
                    } else if context.isAccumulatingInitialUppercase {
                        // "HTTPProxy"/"HTTP_Proxy"/"HTTP_proxy" should all become "httpProxy" when
                        // capitalize == false, which means treating the first word differently: while
                        // lowercasing, lowercase every consecutive uppercase character for as long as
                        // another uppercase character follows it.
                        if char.isLowercase {
                            buffer.append(char)
                            context.isAccumulatingInitialUppercase = false
                        } else {
                            let suffix = documentedName.suffix(from: documentedName.index(after: index))
                            if suffix.count >= 2 {
                                let next = suffix.first!
                                let secondNext = suffix.dropFirst().first!
                                if next.isUppercase && secondNext.isLowercase {
                                    // Finished lowercasing.
                                    context.isAccumulatingInitialUppercase = false
                                    buffer.append(contentsOf: char.lowercased())
                                } else if wordSeparators.contains(next) {
                                    // Finished lowercasing.
                                    context.isAccumulatingInitialUppercase = false
                                    buffer.append(contentsOf: char.lowercased())
                                } else if next.isUppercase {
                                    // Keep lowercasing.
                                    buffer.append(contentsOf: char.lowercased())
                                } else {
                                    // Append as-is, stop accumulating.
                                    context.isAccumulatingInitialUppercase = false
                                    buffer.append(char)
                                }
                            } else {
                                // Last or second to last character; since we were accumulating capitals,
                                // lowercase it.
                                buffer.append(contentsOf: char.lowercased())
                                context.isAccumulatingInitialUppercase = false
                            }
                        }
                    } else {
                        buffer.append(char)
                    }
                    state = .accumulatingFirstWord(context)
                } else if ["_", "-", " ", "/", "+"].contains(char) {
                    // Word separators: remove the character and end the current word.
                    state = .waitingForWordStarter
                } else if ["."].contains(char) {
                    // Replaced with an underscore, but continues the current word.
                    buffer.append("_")
                    state = .accumulatingFirstWord(.init(isAccumulatingInitialUppercase: false))
                } else if ["{", "}"].contains(char) {
                    // Curly braces are dropped.
                    state = .accumulatingFirstWord(.init(isAccumulatingInitialUppercase: false))
                } else {
                    // Illegal character, keep and let the defensive strategy deal with it.
                    state = .accumulatingFirstWord(.init(isAccumulatingInitialUppercase: false))
                    buffer.append(char)
                }
            case .accumulatingWord:
                if char.isLetter || char.isNumber {
                    if isAllUppercase { buffer.append(contentsOf: char.lowercased()) } else { buffer.append(char) }
                    state = .accumulatingWord
                } else if wordSeparators.contains(char) {
                    state = .waitingForWordStarter
                } else if ["."].contains(char) {
                    buffer.append("_")
                    state = .accumulatingWord
                } else if ["{", "}"].contains(char) {
                    state = .accumulatingWord
                } else {
                    // Illegal character, keep and let the defensive strategy deal with it.
                    state = .accumulatingWord
                    buffer.append(char)
                }
            case .waitingForWordStarter:
                if ["_", "-", ".", "/", "+", "{", "}"].contains(char) {
                    // Between words, drop allowed special characters.
                    state = .waitingForWordStarter
                } else if char.isLetter || char.isNumber {
                    // Starting a new word in the middle of the identifier.
                    buffer.append(contentsOf: char.uppercased())
                    state = .accumulatingWord
                } else {
                    // Illegal character, keep and let the defensive strategy deal with it.
                    state = .waitingForWordStarter
                    buffer.append(char)
                }
            case .modifying: preconditionFailure("Logic error in \(#function), string: '\(documentedName)'")
            }
            precondition(state != .modifying, "Logic error in \(#function), string: '\(documentedName)'")
        }
        // Both idiomatic paths end in the defensive strategy, which is what prefixes keywords and
        // leading digits.
        return defensiveSwiftName(for: String(buffer))
    }

    // MARK: - tables

    static let wordSeparators: Set<Character> = ["_", "-", " ", "/", "+"]

    /// A list of Swift keywords. Upstream's comment: "Copied from SwiftSyntax/TokenKind.swift" — so this
    /// is a copy of a copy, and the outer one is the one to re-check on a generator bump.
    static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "func", "import", "init", "inout", "let", "operator",
        "precedencegroup", "protocol", "struct", "subscript", "typealias", "var", "fileprivate", "internal", "private",
        "public", "static", "defer", "if", "guard", "do", "repeat", "else", "for", "in", "while", "return", "break",
        "continue", "fallthrough", "switch", "case", "default", "where", "catch", "throw", "as", "Any", "false", "is",
        "nil", "rethrows", "super", "self", "Self", "true", "try", "throws", "yield", "String", "Error", "Int", "Bool",
        "Array", "Type", "type", "Protocol", "await",
    ]

    /// ASCII printable characters to their HTML entity names, used to reduce collisions.
    static let specialCharsMap: [Unicode.Scalar: String] = [
        " ": "space", "!": "excl", "\"": "quot", "#": "num", "$": "dollar", "%": "percnt", "&": "amp", "'": "apos",
        "(": "lpar", ")": "rpar", "*": "ast", "+": "plus", ",": "comma", "-": "hyphen", ".": "period", "/": "sol",
        ":": "colon", ";": "semi", "<": "lt", "=": "equals", ">": "gt", "?": "quest", "@": "commat", "[": "lbrack",
        "\\": "bsol", "]": "rbrack", "^": "hat", "`": "grave", "{": "lcub", "|": "verbar", "}": "rcub", "~": "tilde",
    ]
}
