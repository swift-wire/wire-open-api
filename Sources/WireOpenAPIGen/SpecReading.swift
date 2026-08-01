import Foundation
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

/// How the witness should spell `registerHandlers`' `serverURL:` argument, read from the document's
/// `servers:` block.
///
/// It cannot be defaulted away. `registerHandlers`' own default is `.defaultOpenAPIServerURL`, which is
/// literally `/` — *not* the document's server — so an operation under `servers: [{url: /api/v1}]` would
/// register at `/tasks/{id}` and 404 at the path the spec describes. (Found by serving it.) The
/// generator emits the document's servers as `Servers.ServerN.url()`, so the witness names the first.
enum ServerPrefix {
    /// No `servers:` block: the generator emits an empty `enum Servers {}`, so naming a server would not
    /// compile. `registerHandlers`' default is then correct — the document describes no prefix.
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
func resolveServerPrefix(specPaths: [String]) -> ServerPrefix {
    // A target's controllers may live apart from the document that describes them (a spec module and an
    // app module), in which case there is nothing to read and the default applies.
    guard specPaths.count == 1, let path = specPaths.first,
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

/// Where an operation registers: the HTTP method, and the path the generator gives it — the document's
/// `paths:` key under the server prefix, which is how `apiPathComponentsWithServerPrefix` composes it.
struct OperationRoute {
    let method: String
    let path: String
}

/// `operationId` → where it registers, read from the document.
///
/// The collector hands back `(method, path)` and nothing else — the generated closure knows the
/// operationId (`forOperation: Operations.GetTask.id`) but never surfaces it — so matching a *method's*
/// declared middleware to a *collected* route has to go through the document.
func resolveOperationRoutes(specPaths: [String]) -> [String: OperationRoute] {
    guard specPaths.count == 1, let path = specPaths.first,
        let contents = try? String(contentsOfFile: path, encoding: .utf8),
        let loaded = ((try? Yams.load(yaml: contents)) ?? nil),
        let document = loaded as? [String: Any],
        let paths = document["paths"] as? [String: Any]
    else { return [:] }

    let servers = (document["servers"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
    let prefix = servers.first.flatMap { URL(string: $0)?.path } ?? ""

    var routes: [String: OperationRoute] = [:]
    for (specPath, item) in paths {
        guard let operations = item as? [String: Any] else { continue }
        for (method, operation) in operations {
            guard let operation = operation as? [String: Any],
                let operationID = operation["operationId"] as? String
            else { continue }
            // `//tasks` and `/api/v1/tasks` both reach the router as the latter; normalise so the emitted
            // match is the path the collector actually reports.
            let joined = (prefix + specPath).replacingOccurrences(of: "//", with: "/")
            routes[operationID] = OperationRoute(method: method.uppercased(), path: joined)
        }
    }
    return routes
}
