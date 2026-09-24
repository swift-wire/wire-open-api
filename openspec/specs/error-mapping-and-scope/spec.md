# Error mapping and request scope

## Purpose

How wire-mvc's `@ErrorResponse` applies to OpenAPI operations, and how a failure entering a request
scope is answered. WireOpenAPIGen checks each mapping against the document, emits the mappings as
`catch` clauses in the operation's forwarder so a mapped error is answered as one of the document's own
responses, and hands the mappings only matchable outside the forwarder to the terminal in
`WireOpenAPIRoutes`. The wire-mvc tier model and request-scope model are specified in wire-mvc and
linked below; this spec states the OpenAPI adaptation.

Rationale: [WireOpenAPIAdvanced](../../../Documentation/Notes/WireOpenAPIAdvanced.md).
Documentation: [ScopeAndErrors](../../../Sources/WireOpenAPI/WireOpenAPI.docc/ScopeAndErrors.md).

## Requirements

### Requirement: The pair form maps only to a response without a body
WireOpenAPIGen SHALL reject `@ErrorResponse(E.self, .status)` on an operation whose documented
response for that status carries a body, with `@ErrorResponse(<E>.self, .<status>) on
'<operationId>' maps to a <code> response that carries a body, so a status alone cannot construct it.
Supply one — @ErrorResponse(<E>.self, .<status>, { e in … }).`

#### Scenario: a pair form against a bodied 404
- **WHEN** operation `opA` documents a 404 with a JSON body and declares `@ErrorResponse(Gone.self, .notFound)`
- **THEN** WireOpenAPIGen reports `@ErrorResponse(Gone.self, .notFound) on 'opA' maps to a 404 response that carries a body, so a status alone cannot construct it. Supply one — @ErrorResponse(Gone.self, .notFound, { e in … }).`

#### Scenario: a pair form against a bodiless 403
- **WHEN** `summariseTask` documents `'403': { description: Not allowed }`, declares `@ErrorResponse(NotAuthorised.self, .forbidden)`, and its handler throws `NotAuthorised` for `GET /api/v1/tasks/secret/summary`
- **THEN** the answer is `403`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`route-scope/pair-form-against-a-bodied-response`), `.github/workflows/build.yml` (job "Fixtures — serve and probe", step "Serve an OpenAPI operation and a @Get route from one router", probe `mappedUndocumented`).

### Requirement: The body form maps only to a response with a JSON body
WireOpenAPIGen SHALL reject `@ErrorResponse(E.self, .status, { e in … })` on an operation whose
documented response for that status carries no content, with `@ErrorResponse(<E>.self, .<status>, …)
on '<operationId>' supplies a body, but the document's <code> response carries none. Drop the closure.`
Where the response carries a JSON body, the forwarder SHALL return that response case built from the
closure's value, serialised by the generated server.

#### Scenario: a closure against a bodiless 404
- **WHEN** `opA` documents a 404 with no content and declares `@ErrorResponse(Gone.self, .notFound, { … })`
- **THEN** WireOpenAPIGen reports `@ErrorResponse(Gone.self, .notFound, …) on 'opA' supplies a body, but the document's 404 response carries none. Drop the closure.`

#### Scenario: a closure against a bodied 404
- **WHEN** `summariseTask` documents a 404 carrying `Problem`, maps `@ErrorResponse(NoSuchTask.self, .notFound, { _ in Components.Schemas.Problem(message: "no such task") })`, and `GET /api/v1/tasks/missing/summary` makes the handler throw `NoSuchTask`
- **THEN** the answer is `404` with a body containing `"message":"no such task"`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`route-scope/closure-form-against-a-bare-response`), `.github/workflows/build.yml` (probe `mappedDocumented`).

### Requirement: Only JSON response bodies can be constructed
WireOpenAPIGen SHALL reject a mapping whose documented response declares more than one content type
or a content type other than `application/json`, with `@ErrorResponse(<E>.self, .<status>) on
'<operationId>' maps to a <code> response whose content type this adapter cannot construct — it
builds JSON bodies only. Use @RawOperation for this operation.`

#### Scenario: a non-JSON 404
- **WHEN** `opA`'s 404 declares a non-JSON content type and `@ErrorResponse(Gone.self, .notFound)` names it
- **THEN** WireOpenAPIGen reports `@ErrorResponse(Gone.self, .notFound) on 'opA' maps to a 404 response whose content type this adapter cannot construct — it builds JSON bodies only. Use @RawOperation for this operation.`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`route-scope/unconstructible-content-type`).

### Requirement: The closure-only form is rejected
WireOpenAPIGen SHALL reject a one-argument `@ErrorResponse` on an `@OpenAPIController` with
`@ErrorResponse's closure form is not supported for OpenAPI operations: it returns a WireMVCOutcome —
a status and bytes — while an operation answers with one of the responses its document declares. Use
@ErrorResponse(E.self, .status) where that response carries no body, or @ErrorResponse(E.self,
.status, { e in … }) where it carries one.`

#### Scenario: a closure mapping on an operation
- **WHEN** an `@Operation` carries `@ErrorResponse({ error in … })`
- **THEN** WireOpenAPIGen reports that message at the attribute

Pinned by: nothing yet.

### Requirement: A route-scope mapping names a status the document declares
WireOpenAPIGen SHALL reject a route-scope mapping, other than a terminal-scoped one, whose status the
operation does not document, with `@ErrorResponse(<E>.self, .<status>) on '<operationId>' maps to a
status the document does not declare for it. It declares <statuses>. A mapped error is answered as one
of the operation's own responses, so the document has to describe it — add it there, or map to one it
already declares.` A route-scope mapping to `.internalServerError` SHALL NOT be reported.

#### Scenario: an undeclared 404
- **WHEN** `opA` documents only 200 and declares `@ErrorResponse(Gone.self, .notFound)`
- **THEN** WireOpenAPIGen reports `@ErrorResponse(Gone.self, .notFound) on 'opA' maps to a status the document does not declare for it. It declares .ok. A mapped error is answered as one of the operation's own responses, so the document has to describe it — add it there, or map to one it already declares.`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`route-scope/status-not-declared`).

### Requirement: A status name must resolve
WireOpenAPIGen SHALL reject a non-terminal-scoped mapping whose status is not the safe name of any
code from 100 to 599 with `@ErrorResponse(<E>.self, .<status>) on '<operationId>' names a status this
adapter cannot resolve. Use one of HTTPResponse.Status's named cases.`

#### Scenario: a misspelled status
- **WHEN** an operation declares `@ErrorResponse(Gone.self, .notFond)`
- **THEN** WireOpenAPIGen reports `@ErrorResponse(Gone.self, .notFond) on '<operationId>' names a status this adapter cannot resolve. Use one of HTTPResponse.Status's named cases.`

Pinned by: nothing yet.

### Requirement: A controller-scope mapping is declared by every operation it covers
For a controller-scope mapping that is not terminal-scoped, WireOpenAPIGen SHALL report once against
the controller every covered operation, that is every operation not mapping the same error type
itself, whose document lacks the status: `@ErrorResponse(<E>.self, .<status>) on '<Controller>' maps
to a status the document does not declare for <operations>. A mapped error is answered as one of the
operation's own responses, so every operation the mapping covers has to declare <code> — add it there,
or move the mapping to the operations that do.` There is no `.internalServerError` exemption at this
scope.

#### Scenario: one operation lacks the status
- **WHEN** `GateController` declares `@ErrorResponse(Gone.self, .notFound)` and its operation `opB` documents no 404
- **THEN** WireOpenAPIGen reports `@ErrorResponse(Gone.self, .notFound) on 'GateController' maps to a status the document does not declare for 'opB'. A mapped error is answered as one of the operation's own responses, so every operation the mapping covers has to declare 404 — add it there, or move the mapping to the operations that do.`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`controller-scope/status-not-declared-for-some-operations`).

### Requirement: A controller-scope mapping's form fits every operation it covers
Across the covered operations that document the status, WireOpenAPIGen SHALL report, in this order,
a response it cannot construct, operations that disagree about carrying a body, a closure where a
response carries none, and a pair form where a response carries a body, each naming the operations
concerned.

#### Scenario: covered operations disagree about a body
- **WHEN** `GateController`'s `@ErrorResponse(Gone.self, .notFound)` covers `opA`, whose 404 carries a body, and `opB`, whose 404 does not
- **THEN** WireOpenAPIGen reports `@ErrorResponse(Gone.self, .notFound) on 'GateController' covers operations whose 404 responses disagree about carrying a body — with: 'opA'; without: 'opB'. One mapping cannot construct both — move it to route scope on each, or make the document agree.`

#### Scenario: a pair form against a bodied response
- **WHEN** `GateController`'s `@ErrorResponse(Gone.self, .notFound)` covers only `opA`, whose 404 carries a body
- **THEN** WireOpenAPIGen reports `@ErrorResponse(Gone.self, .notFound) on 'GateController' maps to a 404 response that carries a body for 'opA', so a status alone cannot construct it. Supply one — @ErrorResponse(Gone.self, .notFound, { e in … }).`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`controller-scope/covered-operations-disagree-about-a-body`, `controller-scope/pair-form-against-a-bodied-response`, `controller-scope/closure-form-against-a-bare-response`, `controller-scope/unconstructible-content-type`, `accepted/per-operation-forms-are-the-remedy-for-disagreement`).

### Requirement: A scoped controller's mapping is declared by operations that shadow it
For a `@Scoped(seed:)` controller, WireOpenAPIGen SHALL also require an operation that maps the same
error type itself to document the controller mapping's status, reporting `@ErrorResponse(<E>.self,
.<status>) on '<Controller>' also answers a failure entering its request scope, which happens before
an operation is dispatched — so it applies to <operations> too, despite their own mapping of the same
error, and the document does not declare <code> there. Add it, or drop the controller-scope mapping.`

#### Scenario: a shadowing operation without the status
- **WHEN** a `@Scoped(seed: HTTPRequest.self)` controller maps `Unauthenticated` to `.unauthorized`, and one of its operations maps `Unauthenticated` itself and documents no 401
- **THEN** WireOpenAPIGen reports that message naming the operation

Pinned by: nothing yet.

### Requirement: A catch-all is last
WireOpenAPIGen SHALL reject a `@ErrorResponse(Error.self, …)` or `@ErrorResponse(Swift.Error.self, …)`
followed, in route-then-controller order, by another mapping, with `@ErrorResponse(<E>.self,
.<status>) on '<operationId>' is a catch-all, so the mappings after it can never match — <types>. Put
the catch-all last.`

#### Scenario: a catch-all before `Gone`
- **WHEN** `opA` declares `@ErrorResponse(Swift.Error.self, .notFound)` and then `@ErrorResponse(Gone.self, …)`
- **THEN** WireOpenAPIGen reports `@ErrorResponse(Swift.Error.self, .notFound) on 'opA' is a catch-all, so the mappings after it can never match — Gone. Put the catch-all last.`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`ordering/catch-all-is-not-last`).

### Requirement: Route scope folds inside controller scope, first match wins
The forwarder SHALL emit one `catch` clause per error type in the order route-scope mappings then
controller-scope mappings, dropping any later mapping of an error type already mapped, so a route-scope
mapping wins over a controller-scope mapping of the same type.

#### Scenario: the same error at both scopes
- **WHEN** `TaskListController` maps `NoSuchTask` to `.internalServerError` and its `summariseTask` maps `NoSuchTask` to `.notFound`
- **THEN** `GET /api/v1/tasks/missing/summary` answers `404`, and `POST /api/v1/tasks/missing/delete`, whose operation does not map it, answers `500`

Pinned by: `.github/workflows/build.yml` (probes `mappedDocumented`, `mappedController`).

### Requirement: Terminal-scoped mappings are exempt from the declared-status rule
A mapping of `DecodingError`, `Error` or `Swift.Error` SHALL NOT be required to name a documented
status. It SHALL be emitted in the forwarder only where the operation documents its status, in which
case its form is checked as any other mapping's, and SHALL always be offered to the terminal. A
mapping of `WireOpenAPIRequestValidationError` SHALL be offered to the terminal as well as emitted in
the forwarder, and remains subject to the declared-status rule.

#### Scenario: a pair form on `DecodingError` against a bodied response
- **WHEN** `opA` declares `@ErrorResponse(DecodingError.self, .notFound)` and documents a 404 with a body
- **THEN** WireOpenAPIGen reports `@ErrorResponse(DecodingError.self, .notFound) on 'opA' maps to a 404 response that carries a body, so a status alone cannot construct it. Supply one — @ErrorResponse(DecodingError.self, .notFound, { e in … }).`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`route-scope/terminal-scoped-pair-form-against-a-bodied-response`).

### Requirement: The terminal answers what the forwarder did not
`WireOpenAPIRoutes.invoke` SHALL answer an error thrown by the generated handler by trying, in order:
the operation's terminal `rejectionResponse` mappings against the error; then, when the error or its
`ServerError.underlyingError` is a `DecodingError`, the converted `WireOpenAPIRequestValidationError`
against the same mappings and otherwise its own 422 answer; then any `HTTPResponseConvertible`
conformance, which is how `ServerError` answers; and otherwise it SHALL rethrow.

#### Scenario: malformed JSON on an operation mapping the validation error
- **WHEN** `POST /api/v1/tasks/new?title=x` sends `Content-Type: application/json` with the body `not json`
- **THEN** the answer is `422`

#### Scenario: a missing body and a wrong content type
- **WHEN** `POST /api/v1/tasks/new?title=hello` sends no body, and separately sends `Content-Type: text/plain`
- **THEN** the answers are `400` and `415`

Pinned by: `.github/workflows/build.yml` (probes `mappedDecode`, `mappedDecodeInside`, `missingBody`, `wrongType`).

### Requirement: A terminal-side mapped response sets only `Content-Type`
The terminal's mapping closure SHALL unwrap `ServerError.underlyingError` before matching, SHALL
answer a pair-form mapping with `HTTPResponse(status:)` and no body, and SHALL answer a body-form
mapping with the closure's value encoded by a default `JSONEncoder` under the single header
`Content-Type: application/json`. A body that fails to encode SHALL fall through to the next clause.

#### Scenario: a body-form mapping answered outside the forwarder
- **WHEN** `GatedTaskController` maps `Unauthenticated` with `{ _ in Components.Schemas.Problem(message: "no user") }` and the scope refuses
- **THEN** the answer is `401` with a body containing `"message":"no user"`

Pinned by: `.github/workflows/build.yml` (probe `gated`).

### Requirement: A failure entering the request scope is answered by controller-scope mappings
For a `@Scoped(seed:)` controller with controller-scope mappings, the generated terminal SHALL enter
the scope through `WireOpenAPIRoutes.enteringScope` and, on failure, call `WireOpenAPIRoutes.refuse`
with a closure built from the controller-scope mappings only. `refuse` SHALL try that closure, then
`HTTPResponseConvertible`, and otherwise rethrow, without reading the request body. A controller with
no controller-scope mappings SHALL enter the scope with a plain `try await`.

#### Scenario: a binding that throws while the scope is built
- **WHEN** `GatedTaskController` injects `RequestGate`, whose `init(seed:)` throws `Unauthenticated` without an `x-user` header, and `GET /api/v1/tasks/42/gated` arrives without one
- **THEN** the answer is `401` with `"message":"no user"` and the global middleware's `x-served-by: wire-open-api` header

#### Scenario: the same operation with the header
- **WHEN** the request carries `x-user: ada`
- **THEN** the answer is `200` with `"title":"task-42 for ada"`

Pinned by: `.github/workflows/build.yml` (probes `gated`, `gatedOK`, `gatedServedBy`).

## Related specifications

- [schema-validation](../schema-validation/spec.md)
- [controller-collation](../controller-collation/spec.md)
- [operation-forms](../operation-forms/spec.md)
- [route-mounting](../route-mounting/spec.md)
- [document-reading](../document-reading/spec.md)
- [build-plugins-and-gen-cli](../build-plugins-and-gen-cli/spec.md)
- [wire-mvc error-response-tiers](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/error-response-tiers/spec.md)
- [wire-mvc request-scope](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/request-scope/spec.md)
