import Foundation
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
/// It cannot be defaulted away. The default is `.defaultOpenAPIServerURL`, which is
/// literally `/` — *not* the document's server — so an operation under `servers: [{url: /api/v1}]` would
/// register at `/tasks/{id}` and 404 at the path the spec describes. (Found by serving it.) The
/// generator emits the document's servers as `Servers.ServerN.url()`, so the witness names the first.
enum ServerPrefix {
    /// No `servers:` block: the generator emits an empty `enum Servers {}`, so naming a server would not
    /// compile. The default is then correct — the document describes no prefix.
    case none
    /// One distinct path prefix across the document's servers — name it.
    case server1
}

/// Resolve the prefix, or exit with a diagnostic when the document's servers disagree.
///
/// Several `servers:` entries are ordinary (prod/staging), and harmless here *as long as their path
/// components agree*: registration uses only the path, so alternatives differing by host register
/// identically. Entries with **different paths** have no single answer — picking the first would
/// silently serve some environments' routes at the wrong prefix — so that is an error rather than a
/// guess.
func resolveServerPrefix(specPath: String?) -> ServerPrefix {
    // A group whose document could not be located reads as "no prefix declared" rather than failing here;
    // `diagnoseCoverage` reports the missing document, with the controller to point at.
    guard let path = specPath,
        let contents = try? String(contentsOfFile: path, encoding: .utf8),
        // `Yams.load` returns `Any?`; casting the optional itself rather than its contents silently
        // yields nothing, which is how this first read as "no servers declared".
        let loaded = ((try? Yams.load(yaml: contents)) ?? nil),
        let document = loaded as? [String: Any]
    else { return .none }

    let servers = (document["servers"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
    guard !servers.isEmpty else { return .none }

    // Compare path components only: `https://prod.example.com/v1` and `https://staging.example.com/v1`
    // register identically.
    let prefixes = Set(servers.map { URL(string: $0)?.path ?? $0 })
    guard prefixes.count == 1 else {
        let listed = servers.sorted().joined(separator: ", ")
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

/// The `requestBody:` entry: whether it must be present, and what it can be.
struct SpecRequestBody {
    let isRequired: Bool
    let contentTypes: [String]
}

/// One `responses:` entry.
struct SpecResponse {
    let code: Int
    /// The content types declared for it, in document order. Empty means a response with no body.
    let contentTypes: [String]
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

/// `operationId` → where it registers, read from the document.
///
/// This is the only source of routing: nothing replays the generated `registerHandlers` to discover what
/// it would have registered, so the document is read directly and each operation is mounted from it.
func resolveOperationRoutes(specPath: String?) -> [String: OperationRoute] {
    guard let path = specPath,
        let contents = try? String(contentsOfFile: path, encoding: .utf8),
        let loaded = ((try? Yams.load(yaml: contents)) ?? nil),
        let document = loaded as? [String: Any],
        let paths = document["paths"] as? [String: Any]
    else { return [:] }

    var routes: [String: OperationRoute] = [:]
    for (specPath, item) in paths {
        guard let item = item as? [String: Any] else { continue }
        let operations = item
        for (method, operation) in operations {
            guard let operation = operation as? [String: Any],
                let operationID = operation["operationId"] as? String
            else { continue }
            // Path-level parameters apply to every operation under that path, so both lists are read.
            let declared =
                (item["parameters"] as? [[String: Any]] ?? []) + (operation["parameters"] as? [[String: Any]] ?? [])
            let parameters = declared.compactMap { entry -> SpecParameter? in
                guard let name = entry["name"] as? String,
                    let rawLocation = entry["in"] as? String,
                    let location = SpecParameter.Location(rawValue: rawLocation)
                else { return nil }
                return SpecParameter(name: name, location: location)
            }
            let declaredResponses = operation["responses"] as? [String: Any] ?? [:]
            let responses =
                declaredResponses
                .compactMap { code, value -> SpecResponse? in
                    guard let code = Int(code) else { return nil }  // `default` and `2XX` are not statuses
                    let content = (value as? [String: Any])?["content"] as? [String: Any] ?? [:]
                    return SpecResponse(code: code, contentTypes: content.keys.sorted())
                }
                .sorted { $0.code < $1.code }
            let declaredBody = operation["requestBody"] as? [String: Any]
            let requestBody = declaredBody.map { entry in
                SpecRequestBody(
                    // OpenAPI's default is `required: false`, which is also the generator's: the `Input`
                    // member is optional unless the document says otherwise.
                    isRequired: entry["required"] as? Bool ?? false,
                    contentTypes: (entry["content"] as? [String: Any] ?? [:]).keys.sorted()
                )
            }
            routes[operationID] = OperationRoute(
                method: method.uppercased(),
                path: specPath,
                parameters: parameters,
                responses: responses,
                requestBody: requestBody
            )
        }
    }
    return routes
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
