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
// Dereferencing is what fixes that class outright rather than case by case: `locallyDereferenced()`
// resolves every internal `$ref` once, so everything downstream sees a document with no references left
// in it and cannot forget to follow one.

/// A document, loaded and fully dereferenced.
func loadDocument(at path: String) -> OpenAPIKit.DereferencedDocument? {
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

    let document: OpenAPIKit.OpenAPI.Document
    do {
        switch version {
        case "3.0.0", "3.0.1", "3.0.2", "3.0.3", "3.0.4":
            document = try decoder.decode(OpenAPIKit30.OpenAPI.Document.self, from: contents).convert(to: .v3_1_0)
        case "3.1.0", "3.1.1", "3.1.2", "3.2.0":
            document = try decoder.decode(OpenAPIKit.OpenAPI.Document.self, from: contents)
        default:
            diagnoseDocument(path, "declares `openapi: \(version)`, which this adapter cannot read.")
        }
    } catch {
        diagnoseDocument(path, "could not be read: \(error)")
    }

    do {
        return try document.locallyDereferenced()
    } catch {
        // An unresolvable reference is worth naming here rather than surfacing later as a parameter or
        // response that appears not to exist. External-file references land here too; the generator does
        // not support them either.
        diagnoseDocument(path, "has a reference that could not be resolved: \(error)")
    }
}

private func diagnoseDocument(_ path: String, _ message: String) -> Never {
    FileHandle.standardError.write(Data("\(path): error: the OpenAPI document \(message)\n".utf8))
    exit(1)
}

// MARK: - what the codegen needs from it

extension OpenAPIKit.DereferencedDocument {
    /// One distinct path prefix across the document's servers, or none.
    ///
    /// Several `servers:` entries are ordinary (prod/staging) and harmless *as long as their path
    /// components agree*: registration uses only the path, so alternatives differing by host register
    /// identically. Entries with different paths have no single answer.
    var serverPathPrefixes: Set<String> {
        Set(
            underlyingDocument.servers.map { server in
                URLComponents(string: server.urlTemplate.absoluteString)?.path ?? server.urlTemplate.absoluteString
            }
        )
    }

    /// `operationId` → where it registers and what it declares.
    ///
    /// Path-level parameters apply to every operation under that path, so both lists are read — the merge
    /// OpenAPIKit leaves to the caller.
    var operationRoutes: [String: OperationRoute] {
        var found: [String: OperationRoute] = [:]
        for route in routes {
            let item = route.pathItem
            for endpoint in item.endpoints {
                guard let operationID = endpoint.operation.operationId else { continue }
                let parameters = (item.parameters + endpoint.operation.parameters)
                    .compactMap { parameter -> SpecParameter? in
                        guard let location = SpecParameter.Location(parameter.context) else { return nil }
                        return SpecParameter(name: parameter.name, location: location)
                    }
                let responses = endpoint.operation.responses
                    .compactMap { statusCode, response -> SpecResponse? in
                        // `default` and range keys (`2XX`) describe no single status, so a typed handler
                        // cannot construct one; they are left out, and the handler is then asked to name
                        // a status it can build — which is the honest failure.
                        guard case .status(code: let code) = statusCode.value else { return nil }
                        return SpecResponse(
                            code: code,
                            contentTypes: response.content.keys.map(\.rawValue).sorted()
                        )
                    }
                    .sorted { $0.code < $1.code }
                let requestBody = endpoint.operation.requestBody.map { body in
                    SpecRequestBody(
                        isRequired: body.required,
                        contentTypes: body.content.keys.map(\.rawValue).sorted()
                    )
                }
                found[operationID] = OperationRoute(
                    method: endpoint.method.rawValue.uppercased(),
                    path: route.path.rawValue,
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
