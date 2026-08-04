import Foundation
import WireOpenAPINaming

// What the codegen refuses, and how it says so.
//
// Every check here exists because its absence fails somewhere worse: inside generated code as "cannot
// find type" or "no member", or not at all — a route that serves a default, middleware that never runs,
// a handler that is never called. The document is the authority throughout; an annotation says *which*
// thing is meant, never *where* it lives or *what* it is.

extension DirectDispatchEmitter {
    /// Routes come from the *document* rather than from replaying a registration, so every operation it
    /// declares has to name a method here. Without the marker there is no method name to call, and no way
    /// to derive one that does not re-do the generator's safe-name transform — so an unmarked operation is
    /// an error naming it, not a route that silently never appears.
    func diagnoseCoverage() {
        if operationRoutes.isEmpty {
            fail(
                """
                @OpenAPIController needs the OpenAPI document to derive its routes, and none was passed \
                (--spec).
                """
            )
        }
        diagnoseDuplicates()
        diagnoseTypedBindings()
        diagnoseTypedResponses()
        let marked = byOperationID
        let missing = operationRoutes.keys.filter { marked[$0] == nil }.sorted()
        guard !missing.isEmpty else { return }
        fail(
            """
            every operation the document declares must carry @RawOperation, and \
            \(missing.joined(separator: ", ")) \(missing.count == 1 ? "does" : "do") not. Mark the \
            \(missing.count == 1 ? "method that implements it" : "methods that implement them").
            """
        )
    }

    /// Two controllers implementing one operationId would each be a plausible target and only one could
    /// be mounted, so the document decides nothing and the choice would be discovery order. Reject it
    /// rather than mount whichever came last.
    func diagnoseDuplicates() {
        var owners: [String: [String]] = [:]
        for controller in controllers {
            for operation in controller.operations {
                owners[operation.operationID, default: []].append(controller.typeName)
            }
        }
        let clashes = owners.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
        guard let (operationID, named) = clashes.first else { return }
        fail(
            """
            \(named.sorted().joined(separator: " and ")) both declare @RawOperation \
            '\(operationID)'. One operation is mounted once, so exactly one controller may implement it.
            """
        )
    }

    /// A typed operation's bindings are checked against the document, which is the authority on where a
    /// parameter lives. Two ways they disagree, both silent otherwise: a name the document does not
    /// declare would read a member that does not exist ("no member" inside generated code), and a
    /// location the document contradicts would read the wrong one — `@Query` on something the spec puts
    /// in the path compiles perfectly and serves nothing.
    func diagnoseTypedBindings() {
        for controller in controllers {
            for operation in controller.operations where operation.isTyped {
                guard let route = operationRoutes[operation.operationID] else { continue }
                for parameter in operation.parameters {
                    guard let declared = route.parameters.first(where: { $0.name == parameter.documentedName })
                    else {
                        let known = route.parameters.map { "'\($0.name)' (\($0.location.rawValue))" }
                            .sorted()
                            .joined(separator: ", ")
                        fail(
                            """
                            @Operation '\(operation.operationID)' binds '\(parameter.documentedName)', which \
                            the document does not declare. It declares \(known.isEmpty ? "no parameters" : known). \
                            Name the documented parameter — @\(parameter.binding)("the-name") — if the Swift \
                            name differs.
                            """,
                            at: operation
                        )
                    }
                    let annotated = parameter.binding.lowercased()
                    guard annotated != declared.location.rawValue else { continue }
                    fail(
                        """
                        @Operation '\(operation.operationID)' annotates '\(parameter.documentedName)' as \
                        @\(parameter.binding), but the document puts it in \(declared.location.rawValue). The \
                        document decides where a parameter lives; the annotation only says which one this is.
                        """,
                        at: operation
                    )
                }
            }
        }
    }

    /// A typed handler constructs one of the document's responses, so three things have to line up: it
    /// must be decidable which one, it must be one the shim can build, and the handler's return has to
    /// match whether that response carries a body.
    func diagnoseTypedResponses() {
        for controller in controllers {
            for operation in controller.operations where operation.isTyped {
                guard let route = operationRoutes[operation.operationID] else { continue }
                let successes = route.responses.filter { (200..<300).contains($0.code) }
                if let written = operation.responseStatus {
                    guard
                        route.responses.contains(where: {
                            GeneratorStatusNames.safeName(for: $0.code) == written
                        })
                    else {
                        let declared = route.responses
                            .map { "\($0.code) (.\(GeneratorStatusNames.safeName(for: $0.code)))" }
                            .joined(separator: ", ")
                        fail(
                            """
                            @JSONResponse(status: .\(written)) on '\(operation.operationID)' names a status \
                            the document does not declare. It declares \(declared.isEmpty ? "none" : declared).
                            """,
                            at: operation
                        )
                    }
                } else if successes.count != 1 {
                    let declared =
                        successes
                        .map { ".\(GeneratorStatusNames.safeName(for: $0.code))" }
                        .joined(separator: ", ")
                    fail(
                        """
                        '\(operation.operationID)' documents \(successes.isEmpty ? "no" : "\(successes.count)") \
                        success \(successes.count == 1 ? "response" : "responses")\
                        \(declared.isEmpty ? "" : " (\(declared))"), so which one the handler returns cannot \
                        be inferred. Name it with @JSONResponse(status:) or @ResponseStatus(_:).
                        """,
                        at: operation
                    )
                }
                diagnoseResponseShape(operation)
            }
        }
    }

    /// The selected response and the handler's signature have to agree: a body needs something returned,
    /// and a no-content response needs nothing.
    private func diagnoseResponseShape(_ operation: DiscoveredOperation) {
        // `@JSONResponse` says "a body, with this status"; `@ResponseStatus` says "this status, no body".
        // Using one where the handler's signature says the other is a contradiction worth naming, since
        // the resulting error would otherwise be about the response's content and not about the mix-up.
        if operation.statusAnnotation == "JSONResponse", operation.returnType == nil {
            fail(
                """
                '\(operation.operationID)' returns nothing but names its status with @JSONResponse, which \
                is for a handler that returns a body. Use @ResponseStatus(.\(operation.responseStatus ?? "")).
                """,
                at: operation
            )
        }
        if operation.statusAnnotation == "ResponseStatus", operation.returnType != nil {
            fail(
                """
                '\(operation.operationID)' returns a body but names its status with @ResponseStatus, which \
                is for a handler that returns nothing. Use \
                @JSONResponse(status: .\(operation.responseStatus ?? "")).
                """,
                at: operation
            )
        }
        do {
            let selected = selectedResponse(for: operation)
            let hasBody = !selected.contentTypes.isEmpty
            if hasBody, selected.contentTypes != ["application/json"] {
                fail(
                    """
                    '\(operation.operationID)' responds with \(selected.contentTypes.joined(separator: ", ")), \
                    which the typed shim cannot construct yet — it builds JSON bodies only. Use \
                    @RawOperation for this operation.
                    """
                )
            }
            if hasBody, operation.returnType == nil {
                fail(
                    """
                    '\(operation.operationID)' documents a \(selected.code) response with a body, but its \
                    handler returns nothing. Return the response body's type.
                    """
                )
            }
            if !hasBody, operation.returnType != nil {
                fail(
                    """
                    '\(operation.operationID)' documents a \(selected.code) response with no content, but \
                    its handler returns \(operation.returnType ?? ""). Drop the return, or document a body.
                    """
                )
            }
        }
    }

    /// Reported against the operation when one is in hand — a controller with six of them is not a
    /// useful place to point — and against the controller otherwise.
    func fail(_ message: String, at operation: DiscoveredOperation? = nil) -> Never {
        let controller = controllers[0]
        let line = operation?.line ?? controller.line
        FileHandle.standardError.write(Data("\(controller.file):\(line): error: \(message)\n".utf8))
        exit(1)
    }
}
