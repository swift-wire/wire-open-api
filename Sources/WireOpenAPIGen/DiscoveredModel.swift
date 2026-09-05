// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-open-api project authors

import Foundation
import SwiftSyntax

// What scanning a controller yields: the operations it declares, how each binds its parameters and its
// response, and the error mappings that surround them. Separated from the scanner itself because the
// emitters read this model far more than the parsing that builds it.

/// The group matches swift-wire's `.contributesAggregateProxy(groupedByAttribute: "spec")`, so the proxy
/// this tool writes an extension on is named for the same value.
/// One `@RawOperation` method: which operation it implements, and the route-scope `@Middleware` it
/// declares. Route middleware folds inside the controller's, so the two are kept separate.
struct DiscoveredOperation {
    let operationID: String
    let middleware: [String]
    /// The method's own name, and its input and output types **exactly as written**.
    ///
    /// Copying the spellings verbatim is what keeps the forwarding conformance free of the generator's
    /// safe-name transform: the forwarder is declared with the same types the user already wrote, so the
    /// codegen never has to derive `Operations.GetTask.Input` from the operationId `getTask` — a
    /// derivation that is identity for some specs and not others.
    let methodName: String
    /// `@RawOperation`: the `Input`/`Output` spellings exactly as written. Nil for a typed operation,
    /// which never names them — that is the point of the shim.
    let inputType: String?
    let outputType: String?
    /// `@Operation`: the parameters to bind and the response body type. Empty and nil for a raw one.
    let parameters: [BoundParameter]
    /// The response body's type, or nil when the handler returns nothing — which is how a documented
    /// no-content response is written.
    let returnType: String?
    /// Whether this operation is bound by the typed shim rather than handed the generated `Input`.
    let isTyped: Bool
    /// The status named by `@JSONResponse(status:)` or `@ResponseStatus(_:)`, as written — `created`.
    /// Nil when the operation documents exactly one success and needs no saying.
    let responseStatus: String?
    /// Which annotation named it, so a handler that returns a body and one that does not can be told
    /// they used the wrong one. `@JSONResponse` carries a body, `@ResponseStatus` does not — the same
    /// split WireMVC draws.
    let statusAnnotation: String?
    /// `@ErrorResponse(SomeError.self, .notFound)` on this method, in source order — route scope, which
    /// folds *inside* the controller's.
    let errorMappings: [ErrorMapping]
    /// The line the method is declared on, so a diagnostic points at the operation rather than at the
    /// controller that happens to contain it.
    let line: Int
}

/// One handler parameter and the `Input` location it reads.
///
/// The wrappers are WireMVC's — `@Path`, `@Query`, `@Header` — so a binding vocabulary is not invented
/// twice. What differs is where the value comes from: WireMVC's `RequestBound.bind` decodes it from the
/// request, while here the generator has already decoded it into `input.path.x` and the shim only has to
/// name that member.
struct BoundParameter {
    /// `Path`, `Query`, `Header`, `JSONBody`, or a **graph-aware** binding's wrapper.
    let binding: String

    /// The worker a graph-aware binding names, or `nil` for an ordinary one.
    ///
    /// Present ⇒ this parameter is **not** a document parameter and never crosses the wire: it is resolved
    /// from the request scope, so the generated `Input` has no member for it and the shim calls the
    /// worker's `bind` instead of projecting one.
    let worker: String?
    /// The seed of the scope `worker` is bound in, resolved where the parameter was scanned. `nil` when
    /// there is no worker, or when its declaration is not in the parsed sources — which is itself the
    /// mistake, and diagnosed as one.
    ///
    /// Carried on the parameter rather than looked up later, so every consumer reads one answer: the scan
    /// is the only place that has both the attribute and the declarations it resolves against.
    let workerSeed: String?
    /// Whether this parameter is resolved from the request scope rather than read out of `Input`.
    var isScopeResolved: Bool { worker != nil }

    /// Whether this parameter binds the request body rather than one of the document's `parameters:`.
    var isBody: Bool { binding == "JSONBody" }
    /// The documented parameter name: `@Path("user-id")` when given, the parameter's own name otherwise —
    /// the same rule WireMVC's route codegen applies.
    let documentedName: String
    /// The call-site label, or nil when the parameter is unlabelled.
    let label: String?
    /// The parameter's own name, used as the documented name when the attribute gives none.
    let name: String
    /// The type exactly as written, which the body binding declares its local with — so the author's
    /// spelling reaches the generated code unaltered, as `@RawOperation`'s always has.
    let type: String
}

/// One `@ErrorResponse(E.self, .status)` pair: an error type, and the status a throw of it becomes.
///
/// The closure form (`@ErrorResponse({ (e: E) in … })`) is WireMVC's, and returns a `WireMVCOutcome` — a
/// status and bytes. An OpenAPI operation returns an `Output`, so the two do not line up, and only the
/// pair form is read for now; the closure form is diagnosed rather than silently ignored.
struct ErrorMapping {
    let errorType: String
    /// The status as written — `notFound` — resolved against the document where the response is built.
    let status: String
    /// The body closure of the three-argument form, verbatim, or nil for the pair form.
    ///
    /// Which of the two is legal is not the author's choice: the document says whether that status
    /// carries a body, and exactly one form can construct what it declares.
    let bodyClosure: String?

    /// Whether this mapping has to be matched at the *terminal* rather than in the forwarder.
    ///
    /// Placement follows what can match where. A `DecodingError` is thrown by the generator's
    /// deserializer *before* the forwarder is entered, so a clause inside it could never see one; a
    /// catch-all is written to cover that case too. Everything else is an error the handler threw, which
    /// only has its own type inside.
    ///
    /// The cost: a handler that itself throws a `DecodingError` — decoding something by hand — is
    /// answered out there with a plain status rather than a documented response. Rare, and the
    /// alternative is emitting the same mapping at both sites, which makes generated code hard to read.
    var isTerminalScoped: Bool { ["DecodingError", "Error", "Swift.Error"].contains(errorType) }

    /// Whether this error can reach the **terminal** — a rejection the forwarder never saw.
    ///
    /// A superset of `isTerminalScoped`, and the two are different questions that used to share an
    /// answer. `isTerminalScoped` also *exempts* a mapping from naming a documented status, which is right
    /// for a `DecodingError`: the request never became this operation's `Input`, so its responses do not
    /// describe the outcome. It is wrong for `WireOpenAPIRequestValidationError`, which arrives at both
    /// sites — thrown by a generated validator inside the forwarder, where it constructs one of the
    /// document's own responses and must name a declared status, *and* produced at the terminal when the
    /// deserializer refused the body. Conflating them would have quietly dropped the must-be-documented
    /// rule for every validation mapping.
    var arrivesAtTerminal: Bool {
        isTerminalScoped || errorType == "WireOpenAPIRequestValidationError"
    }

    /// A catch-all matches every error, so nothing after it can run.
    var isCatchAll: Bool { ["Error", "Swift.Error"].contains(errorType) }
}

struct DiscoveredController {
    let typeName: String
    /// The module this controller is *declared* in — not the one being compiled. They differ whenever a
    /// controller ships in a library, which is the ordinary case for a shared spec.
    let homeModule: String
    /// The controller's own generic parameters, in source order. Empty for a concrete controller.
    let genericParameters: [GenericParameter]
    /// Its `where` clause verbatim, if it has one.
    let genericWhereClause: String?
    let spec: String?
    /// The verbatim argument of each type-level `@Middleware`, in source order — controller-scope
    /// middleware, folded around every one of this controller's operations.
    let middleware: [String]
    /// The controller's `@RawOperation` methods, in source order.
    let operations: [DiscoveredOperation]
    /// Controller-scope `@ErrorResponse`, folded around every one of this controller's operations —
    /// outside the route-scope ones, matching WireMVC's first-match-wins order.
    let errorMappings: [ErrorMapping]
    /// The `@Scoped(seed:)` seed type, if the controller is request-scoped — in which case the aggregate
    /// bridges into its scope per request instead of holding it.
    let seed: String?
    let file: String
    let line: Int

    /// The controller's type as the conformer writes it, with this controller's parameters renamed by
    /// `prefix` — `TaskController<_wireC0Store>`.
    ///
    /// Renaming rather than reusing the written names is what keeps the conformer independent of
    /// swift-wire's aggregate proxy. Two controllers on one spec can each declare a `Store`, and the proxy
    /// holds them as *different* parameters, which it disambiguates by its own rule (`Store`, `Store2`).
    /// Guessing that rule would couple the two emitters; instead every controller's parameters get a
    /// per-controller prefix here, and the construction site passes the proxy's fields, so the compiler
    /// infers each one from the value's type. Neither emitter has to know the other's names.
    func subjectType(prefix: String) -> String {
        genericParameters.isEmpty
            ? typeName
            : "\(typeName)<\(genericParameters.map { prefix + $0.name }.joined(separator: ", "))>"
    }

    /// This controller's parameters as a conformer clause writes them, renamed by `prefix`.
    func genericDeclarations(prefix: String) -> [String] {
        genericParameters.map { parameter in
            parameter.inheritedType.map { "\(prefix)\(parameter.name): \($0)" } ?? prefix + parameter.name
        }
    }
}
