import Foundation
import OpenAPIKit
import WireOpenAPINaming
import Yams

// What the codegen needs from the OpenAPI document itself: the server prefix an operation registers
// under, and where each operationId registers. Both are read from `openapi.yaml` — a *source* file of
// the target — never from the OpenAPI generator's emitted Swift, which would be an undeclared build
// input (spike-28, finding 1).

// MARK: - proxy field names

// The fields a `@Middleware` fold reads are emitted by **swift-wire**, so these rules have to match its
// `.injectsFromGraph` pass — and they match wire-mvc's `RouteCodegen` copies, which derive them the same
// way. Three derivations of one contract is two too many; the rules belong in swift-wire, which owns the
// emission, with both adapters reading them. Until then the compiler is the check: a mismatch is a
// "no member" error at the fold, exactly as the `_wireSubject` handshake is.

/// `_wire` + the simple (generics- and namespace-stripped) type name, upper-cameled —
/// `Mod.RequireAPIKey<…>` → `_wireRequireAPIKey`.
func dependencyPropertyName(forType type: String) -> String {
    let withoutGenerics = type.prefix { $0 != "<" }
    let simple = withoutGenerics.split(separator: ".").last.map(String.init) ?? String(withoutGenerics)
    return "_wire" + simple.prefix(1).uppercased() + simple.dropFirst()
}

/// A key reference reduced to an identifier fragment — `Keys.audit` → `Keys_audit`.
func sanitizedKeyFragment(_ key: String) -> String {
    String(key.map { $0.isLetter || $0.isNumber ? $0 : "_" })
}

// MARK: - the server prefix

/// How the witness should spell the `UniversalServer`'s `serverURL:` argument, read from the document's
/// `servers:` block.
///
/// It cannot be defaulted away. The default is `.defaultOpenAPIServerURL`, which is literally `/` — *not*
/// the document's server — so an operation under `servers: [{url: /api/v1}]` would register at
/// `/tasks/{id}` and 404 at the path the spec describes. (Found by serving it.) The generator emits the
/// document's servers as `Servers.ServerN.url()`, so the witness names the first.
enum ServerPrefix {
    /// No `servers:` block: the generator emits an empty `enum Servers {}`, so naming a server would not
    /// compile. `registerHandlers`' default is then correct — the document describes no prefix.
    case none
    /// One distinct path prefix across the document's servers — name it.
    case server1
}

/// Resolve the prefix, or exit with a diagnostic when the document's servers disagree.
func resolveServerPrefix(document: OpenAPIKit.OpenAPI.Document?, path: String) -> ServerPrefix {
    guard let document else { return .none }
    let prefixes = document.serverPathPrefixes
    guard !prefixes.isEmpty else { return .none }
    guard prefixes.count == 1 else {
        let listed = prefixes.sorted().joined(separator: ", ")
        FileHandle.standardError.write(
            Data(
                """
                \(path): error: the document declares servers with different paths (\(listed)). \
                Operations register under one prefix, so there is no single answer — give the servers a \
                common path, or split the document.

                """.utf8
            )
        )
        exit(1)
    }
    return .server1
}

/// Where an operation registers: the HTTP method, and the document's `paths:` key **unjoined**. The
/// server prefix is applied at registration by the runtime's own `apiPathComponentsWithServerPrefix`, so
/// there is only ever one derivation of that rule.
struct OperationRoute {
    let method: String
    let path: String
    /// The operation's declared parameters, which is what tells the typed shim whether a handler
    /// parameter reads `input.path.x`, `input.query.x` or `input.headers.x`. The document is the only
    /// authority for that: a binding annotation restating it could disagree with it.
    let parameters: [SpecParameter]
    /// The operation's declared responses. The typed shim constructs one of these, so which status and
    /// which content type is a question the document answers.
    let responses: [SpecResponse]
    /// The declared `requestBody`, if any. Nil means the operation takes none — and a handler that binds
    /// one anyway is reading a member the generated `Input` does not have.
    let requestBody: SpecRequestBody?
}

/// The assertions a schema declares, reduced to the ones this adapter can check.
///
/// Read from the document rather than from the generated Swift, like everything else here. The shape
/// mirrors the runtime's `WireOpenAPIValidate` calls one-for-one, so emission is a transcription rather
/// than a translation with judgement in it.
indirect enum SpecAssertions {
    /// Nothing to check — including the cases where the *generator* already did it. An `enum` becomes a
    /// Swift enum and `required` becomes non-optional, so neither needs a runtime check, and emitting one
    /// would not compile anyway: the member's type is the enum, not `String`.
    case none
    case string(minLength: Int?, maxLength: Int?, pattern: String?)
    case integer(minimum: Int?, exclusiveMinimum: Bool, maximum: Int?, exclusiveMaximum: Bool, multipleOf: Int?)
    case number(
        minimum: Double?,
        exclusiveMinimum: Bool,
        maximum: Double?,
        exclusiveMaximum: Bool,
        multipleOf: Double?
    )
    case array(minItems: Int?, maxItems: Int?, uniqueItems: Bool, items: SpecAssertions)
    /// A `$ref` to a component schema, by its **document** name. Kept as a name rather than resolved so
    /// emission becomes a call to that schema's validator — which is what makes recursion terminate and
    /// keeps code size linear in the document rather than in operations × depth.
    case reference(String)
    /// An object, reached by walking its properties. Anonymous ones are walked in place: only a *named*
    /// schema needs its Swift type spelled, and an inline payload's type name
    /// (`Operations.X.Input.Body.JsonPayload.NestedPayload`) is a spelling worth never deriving.
    case object(properties: [SpecProperty])
    /// `allOf`. The generated struct holds one member per subschema, `value1`/`value2` positionally.
    case composed(members: [SpecComposedMember])
    /// Assertions the document makes that this adapter cannot apply, carried so the *diagnostic* can name
    /// the keywords rather than the emitter silently dropping them.
    case unrepresentable(keywords: [String], reason: String)

    /// Whether emission should produce nothing at all. Load-bearing: a document declaring no assertions
    /// must cost an existing consumer nothing, which is what makes always-on validation acceptable.
    var isEmpty: Bool {
        switch self {
        case .none: return true
        case .array(let minItems, let maxItems, let uniqueItems, let items):
            return minItems == nil && maxItems == nil && !uniqueItems && items.isEmpty
        // A reference is never empty *here*: whether the schema it names asserts anything is that
        // schema's question, answered where its validator is emitted. Treating it as empty would prune
        // the walk before reaching the assertions it leads to.
        case .reference: return false
        case .object(let properties): return properties.allSatisfy(\.assertions.isEmpty)
        case .composed(let members): return members.allSatisfy(\.assertions.isEmpty)
        default: return false
        }
    }
}

/// One property of an object schema.
struct SpecProperty {
    /// The name as the document writes it, which is also what the wire carries and what a failure reports.
    let name: String
    /// Whether the document lists it in `required:`, which is exactly when the generator emits a
    /// non-optional member — so it decides whether access needs an `?`.
    let isRequired: Bool
    let assertions: SpecAssertions
}

/// One member of an `allOf`, in document order.
///
/// The generated struct names them `value1`, `value2`, … positionally. They have **no wire counterpart**:
/// the generated `init(from:)` decodes every member from the same decoder, so a failure inside one is
/// reported at the *parent's* path, not under `value1`.
struct SpecComposedMember {
    let index: Int
    let assertions: SpecAssertions
}

/// One `parameters:` entry — its documented name, where it lives, and what it asserts.
struct SpecParameter {
    let name: String
    let location: Location
    /// What the parameter's schema asserts about its value.
    let assertions: SpecAssertions

    /// The `Input` member each location is reached through. `headers` is plural; the other two are not.
    enum Location: String {
        case path
        case query
        case header

        var inputMember: String {
            switch self {
            case .path: return "path"
            case .query: return "query"
            case .header: return "headers"
            }
        }
    }
}

/// One `responses:` entry.
struct SpecResponse {
    let code: Int
    /// The content types declared for it, in document order. Empty means a response with no body.
    let contentTypes: [String]
}

/// The `requestBody:` entry: whether it must be present, and what it can be.
struct SpecRequestBody {
    let isRequired: Bool
    let contentTypes: [String]
    /// What the JSON schema of this body asserts. Only the JSON one: it is the only content type whose
    /// value the generator gives a schema-derived Swift type, so it is the only one a validator can walk.
    let assertions: SpecAssertions
}

// MARK: - the naming strategy

/// The strategy a document is generated with, read from its `openapi-generator-config.yaml`.
///
/// It has to be read rather than assumed: it changes the spelling of every generated symbol the typed
/// shim names, and the generator's default is **defensive**, not idiomatic — so a config that simply
/// omits the key is not the arrangement most examples show.
func resolveNamingStrategy(configPath: String?) -> GeneratorNamingStrategy {
    guard let configPath,
        let contents = try? String(contentsOfFile: configPath, encoding: .utf8),
        let loaded = ((try? Yams.load(yaml: contents)) ?? nil),
        let document = loaded as? [String: Any],
        let raw = document["namingStrategy"] as? String,
        let strategy = GeneratorNamingStrategy(rawValue: raw)
    else { return .generatorDefault }
    return strategy
}
