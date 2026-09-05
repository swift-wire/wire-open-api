// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-open-api project authors

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
        diagnoseUndeclaredOperations()
        diagnoseErrorMappings()
        diagnoseControllerErrorMappings()
        diagnoseCatchAllOrdering()
        diagnoseTypedBindings()
        diagnoseTypedResponses()
        diagnoseParameterAssertions()
        let marked = byOperationID
        let missing = operationRoutes.keys.filter { marked[$0] == nil }.sorted()
        guard !missing.isEmpty else { return }
        fail(
            """
            every operation the document declares must be implemented, and \
            \(missing.joined(separator: ", ")) \(missing.count == 1 ? "is" : "are") not. Mark the \
            \(missing.count == 1 ? "method that implements it" : "methods that implement them") with \
            @Operation or @RawOperation.
            """
        )
    }

    /// A marked method naming an operation the document does not declare.
    ///
    /// Without this the method is simply never mounted — nothing registers it, because registration
    /// iterates the *document* — while the conformer still emits a forwarder for it, naming types derived
    /// from an id that describes nothing. The failure then lands inside generated code as
    /// "'GhostOperation' is not a member type of enum 'Operations'", which says nothing about the marker
    /// that caused it.
    private func diagnoseUndeclaredOperations() {
        for controller in controllers {
            for operation in controller.operations where operationRoutes[operation.operationID] == nil {
                let declared = operationRoutes.keys.sorted()
                let listed =
                    declared.isEmpty
                    ? "The document declares none."
                    : "It declares \(declared.map { "'\($0)'" }.joined(separator: ", "))."
                fail(
                    """
                    '\(operation.methodName)' is marked as operation '\(operation.operationID)', which the \
                    document does not declare. \(listed)
                    """,
                    at: operation
                )
            }
        }
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
    /// A graph-aware parameter needs its worker constructed, which only the owning controller's own scope
    /// entry does. Both failures are the *parameter's*, not either type's, so both are reported here.
    private func diagnoseScopeResolvedParameter(
        _ parameter: BoundParameter,
        on controller: DiscoveredController,
        in operation: DiscoveredOperation
    ) {
        guard let worker = parameter.worker else { return }
        guard let workerSeed = parameter.workerSeed else {
            fail(
                """
                @Operation '\(operation.operationID)' binds '\(parameter.name)' through '\(worker)', which \
                is not a @Scoped(seed:) binding. A binding resolved from the request scope has to be one — \
                that is what puts it in the scope its controller enters.
                """,
                at: operation
            )
            return
        }
        guard let controllerSeed = controller.seed else {
            fail(
                """
                @Operation '\(operation.operationID)' binds '\(parameter.name)' through '\(worker)', which \
                is bound in @Scoped(seed: \(workerSeed).self) — but '\(controller.typeName)' is not scoped, \
                so it is held directly and enters no scope, and there is nothing to construct '\(worker)' \
                in. Mark '\(controller.typeName)' @Scoped(seed: \(workerSeed).self).
                """,
                at: operation
            )
            return
        }
        guard controllerSeed == workerSeed else {
            fail(
                """
                @Operation '\(operation.operationID)' binds '\(parameter.name)' through '\(worker)', which \
                is bound in @Scoped(seed: \(workerSeed).self), but '\(controller.typeName)' is in \
                @Scoped(seed: \(controllerSeed).self) — sibling seeded scopes are isolated by design, so \
                its scope entry constructs only its own.
                """,
                at: operation
            )
            return
        }
    }

    func diagnoseTypedBindings() {
        for controller in controllers {
            for operation in controller.operations where operation.isTyped {
                guard let route = operationRoutes[operation.operationID] else { continue }
                diagnoseRequestBody(operation, route)
                for parameter in operation.parameters where !parameter.isBody {
                    // A graph-aware parameter is not a document parameter, and asking the document about
                    // it is the wrong question: what it binds is resolved from the request scope and never
                    // crosses the wire, so no `parameters:` entry could describe it. What it *does* need
                    // is a scope to be resolved from.
                    if parameter.isScopeResolved {
                        diagnoseScopeResolvedParameter(parameter, on: controller, in: operation)
                        continue
                    }
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

    /// A `@JSONBody` parameter and the document's `requestBody` have to agree — on existing at all, on
    /// content type, and on whether the body may be absent. The last one matters most: the generated
    /// `Input.body` is optional exactly when the document says the body is not required, so a handler
    /// disagreeing produces a type error inside generated code rather than at the declaration.
    private func diagnoseRequestBody(_ operation: DiscoveredOperation, _ route: OperationRoute) {
        let bound = operation.parameters.filter(\.isBody)
        guard bound.count <= 1 else {
            fail(
                "'\(operation.operationID)' binds \(bound.count) request bodies. An operation has one.",
                at: operation
            )
        }
        guard let parameter = bound.first else {
            guard route.requestBody != nil else { return }
            fail(
                """
                '\(operation.operationID)' documents a request body, but its handler binds none. Take it \
                with @JSONBody, or use @RawOperation.
                """,
                at: operation
            )
        }
        guard let documented = route.requestBody else {
            fail(
                """
                '\(operation.operationID)' binds a @JSONBody, but the document declares no request body \
                for it.
                """,
                at: operation
            )
        }
        diagnoseRequestBodyShape(operation, documented, parameter)
    }

    /// Content type and optionality, once both sides are known to exist.
    private func diagnoseRequestBodyShape(
        _ operation: DiscoveredOperation,
        _ documented: SpecRequestBody,
        _ parameter: BoundParameter
    ) {
        guard documented.contentTypes == ["application/json"] else {
            let listed = documented.contentTypes.joined(separator: ", ")
            fail(
                """
                '\(operation.operationID)' documents a request body of \(listed.isEmpty ? "no content type" : listed), \
                which @JSONBody cannot decode — it reads JSON only. Use @RawOperation for this operation.
                """,
                at: operation
            )
        }
        let isOptional = parameter.type.hasSuffix("?")
        guard documented.isRequired == !isOptional else {
            fail(
                documented.isRequired
                    ? """
                    '\(operation.operationID)' documents a required request body, but its handler takes \
                    \(parameter.type). Drop the optionality.
                    """
                    : """
                    '\(operation.operationID)' documents an optional request body, but its handler takes \
                    \(parameter.type). Make it optional — the document does not promise one will arrive.
                    """,
                at: operation
            )
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
    func fail(
        _ message: String,
        at operation: DiscoveredOperation? = nil,
        in controller: DiscoveredController? = nil
    ) -> Never {
        // The owning controller when the caller knows it: a group's controllers can live in different
        // files, so reporting everything against the first one would point at the wrong source.
        let source = controller ?? controllers[0]
        let line = operation?.line ?? source.line
        FileHandle.standardError.write(Data("\(source.file):\(line): error: \(message)\n".utf8))
        exit(1)
    }
}
