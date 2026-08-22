import Foundation
import OpenAPIKit
import OpenAPIKit30
import OpenAPIKitCompat
import Yams

// Reading the OpenAPI document with OpenAPIKit — the same model swift-openapi-generator reads it with.
//
// This replaced a dictionary walk over Yams' output. That walk worked for documents shaped like the
// fixture's and quietly mishandled ones that were not: a parameter declared by `$ref` has no `name` key,
// so it was dropped, and a handler binding it was then rejected for binding "a parameter the document
// does not declare" — a false error against a perfectly ordinary document. `default` and `2XX` response
// keys, path-level parameters and referenced request bodies had the same shape of problem.
//
// References are resolved **one hop at a time**, against the Components Object, at each of the four
// places this codegen actually reads: the path item, its parameters, the operation's responses and its
// request body. It does *not* ask for a fully dereferenced document.
//
// That distinction is the whole of this file's care, and it was bought by a bug. `locallyDereferenced()`
// resolves every internal `$ref` in one pass — including schema references, which are the ones that can
// legitimately form a cycle. A `Node` whose `children` are `Node`s is ordinary OpenAPI, and
// swift-openapi-generator supports it outright: it has a `RecursionDetector` and boxes the recursive type.
// OpenAPIKit refuses it, by design and with a good message — *"attempting to [fully resolve] results in
// an infinite loop over any reference cycles… `lookupOnce()` is your best option in this case"* — and the
// adapter turned that into `error: the OpenAPI document has a reference that could not be resolved`.
// So a document the generator compiled happily failed this tool, and the message blamed the reference
// rather than the cycle.
//
// One-hop lookup is the fix OpenAPIKit's own error recommends, and it costs nothing here, because
// **nothing in this codegen reads a schema.** It needs a parameter's name and location, a response's
// status and content-type keys, and whether a request body is required — all of which sit on the
// Parameter, Response and Request objects themselves. Those live in the Components Object as concrete
// values, so one hop always lands on one. Schema `$ref`s are never followed, so a schema cycle is not
// merely tolerated: it is never visited.

/// A document, loaded. References are resolved where they are read, not up front — see above.
func loadDocument(at path: String) -> OpenAPIKit.OpenAPI.Document? {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let decoder = YAMLDecoder()

    // The version decides which model decodes it, exactly as the generator does it: 3.0 documents are
    // decoded by OpenAPIKit30 and converted, so a 3.0 document this adapter reads is the same 3.1
    // document the generator generated from.
    struct VersionedDocument: Decodable { var openapi: String? }
    guard let versioned = try? decoder.decode(VersionedDocument.self, from: contents),
        let version = versioned.openapi
    else {
        diagnoseDocument(path, "has no `openapi:` version, so it cannot be read as an OpenAPI document.")
    }

    do {
        switch version {
        case "3.0.0", "3.0.1", "3.0.2", "3.0.3", "3.0.4":
            return try decoder.decode(OpenAPIKit30.OpenAPI.Document.self, from: contents).convert(to: .v3_1_0)
        case "3.1.0", "3.1.1", "3.1.2", "3.2.0":
            return try decoder.decode(OpenAPIKit.OpenAPI.Document.self, from: contents)
        default:
            diagnoseDocument(path, "declares `openapi: \(version)`, which this adapter cannot read.")
        }
    } catch {
        diagnoseDocument(path, "could not be read: \(error)")
    }
}

private func diagnoseDocument(_ path: String, _ message: String) -> Never {
    FileHandle.standardError.write(Data("\(path): error: the OpenAPI document \(message)\n".utf8))
    exit(1)
}

// MARK: - what the codegen needs from it

extension OpenAPIKit.OpenAPI.Document {
    /// One distinct path prefix across the document's servers, or none.
    ///
    /// Several `servers:` entries are ordinary (prod/staging) and harmless *as long as their path
    /// components agree*: registration uses only the path, so alternatives differing by host register
    /// identically. Entries with different paths have no single answer.
    var serverPathPrefixes: Set<String> {
        Set(
            servers.map { server in
                URLComponents(string: server.urlTemplate.absoluteString)?.path ?? server.urlTemplate.absoluteString
            }
        )
    }

    /// Resolve one `$ref`-or-value, reporting an unresolvable reference against the document.
    ///
    /// An external reference lands here too; the generator does not support those either, so naming it
    /// as unresolvable is honest. What no longer lands here is a *schema* cycle — nothing this codegen
    /// reads reaches a schema, so there is no cycle to hit.
    /// `T` is qualified because **both** OpenAPIKit and OpenAPIKit30 declare a protocol of this name,
    /// and this file imports both to convert 3.0 documents — the same-spelling-across-modules hazard the
    /// *Coupling inventory* tracks, arriving here as "ambiguous for type lookup".
    private func resolve<T: OpenAPIKit.ComponentDictionaryLocatable>(
        _ maybeReference: Either<OpenAPIKit.OpenAPI.Reference<T>, T>,
        _ what: String,
        at documentPath: String
    ) -> T {
        do {
            return try components.lookup(maybeReference)
        } catch {
            diagnoseDocument(documentPath, "has \(what) that could not be resolved: \(error)")
        }
    }

    /// `operationId` → where it registers and what it declares.
    ///
    /// Path-level parameters apply to every operation under that path, so both lists are read — the merge
    /// OpenAPIKit leaves to the caller.
    ///
    /// Takes the document's path so an unresolvable reference is reported against the file the author can
    /// open, rather than surfacing later as a parameter or response that appears not to exist.
    func operationRoutes(documentPath: String) -> [String: OperationRoute] {
        var found: [String: OperationRoute] = [:]
        for (path, pathItemReference) in paths {
            // Resolved explicitly rather than through `Document.routes`, which looks path items up with a
            // non-throwing subscript and **silently drops** one it cannot resolve. That would surface as
            // an operationId the document appears not to declare — a diagnostic pointing at the
            // controller for a fault in the document.
            let item = resolve(
                    pathItemReference, "a path item reference for '\(path.rawValue)'", at: documentPath
                )
            for endpoint in item.endpoints {
                guard let operationID = endpoint.operation.operationId else { continue }
                let parameters = (item.parameters + endpoint.operation.parameters)
                    .compactMap { parameterReference -> SpecParameter? in
                        let parameter = resolve(
                            parameterReference,
                            "a parameter reference in '\(operationID)'",
                            at: documentPath
                        )
                        guard let location = SpecParameter.Location(parameter.context) else { return nil }
                        return SpecParameter(name: parameter.name, location: location)
                    }
                let responses = endpoint.operation.responses
                    .compactMap { statusCode, responseReference -> SpecResponse? in
                        // `default` and range keys (`2XX`) describe no single status, so a typed handler
                        // cannot construct one; they are left out, and the handler is then asked to name
                        // a status it can build — which is the honest failure.
                        guard case .status(code: let code) = statusCode.value else { return nil }
                        let response = resolve(
                            responseReference,
                            "a reference for the \(code) response of '\(operationID)'",
                            at: documentPath
                        )
                        return SpecResponse(
                            code: code,
                            contentTypes: response.content.keys.map(\.rawValue).sorted()
                        )
                    }
                    .sorted { $0.code < $1.code }
                let requestBody = endpoint.operation.requestBody.map { bodyReference in
                    let body = resolve(
                        bodyReference, "a request body reference in '\(operationID)'", at: documentPath
                    )
                    return SpecRequestBody(
                        isRequired: body.required,
                        contentTypes: body.content.keys.map(\.rawValue).sorted()
                    )
                }
                found[operationID] = OperationRoute(
                    method: endpoint.method.rawValue.uppercased(),
                    path: path.rawValue,
                    parameters: parameters,
                    responses: responses,
                    requestBody: requestBody
                )
            }
        }
        return found
    }
}

extension SpecParameter.Location {
    /// OpenAPIKit models a parameter's location as a context carrying its own requiredness; only the
    /// location matters here. `cookie` has no `Input` member the shim can read, so it is not one.
    init?(_ context: OpenAPIKit.OpenAPI.Parameter.Context) {
        switch context {
        case .path: self = .path
        case .query: self = .query
        case .header: self = .header
        // `cookie`, and anything a later OpenAPI version adds, has no `Input` member the shim can read.
        default: return nil
        }
    }
}
