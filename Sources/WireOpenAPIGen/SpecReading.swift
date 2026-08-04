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
func resolveServerPrefix(document: OpenAPIKit.DereferencedDocument?, path: String) -> ServerPrefix {
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

/// One `parameters:` entry — its documented name and where it lives.
struct SpecParameter {
    let name: String
    let location: Location

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
