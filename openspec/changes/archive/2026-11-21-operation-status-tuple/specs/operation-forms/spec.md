## MODIFIED Requirements

### Requirement: A single documented success is inferred, several must be named
An `@Operation` naming no status and not returning a status in a response tuple SHALL construct the
operation's one documented `2xx` response, and SHALL be refused when the document declares zero or
several with
`error: '<id>' documents <n> success responses (<cases>), so which one the handler returns cannot be inferred. Name it with @JSONResponse(status:) or @ResponseStatus(_:), or return (status:body:) to choose one per call.`
(`no` in place of `<n>`, and no parenthesised list, when there are none). A status named with
`@JSONResponse(status:)` or `@ResponseStatus(_:)` SHALL be matched against the document's responses
by `GeneratorStatusNames.safeName(for:)`, and one the document does not declare SHALL be refused with
`error: @JSONResponse(status: .<name>) on '<id>' names a status the document does not declare. It declares <code> (.<case>), ….`
The message SHALL say `@JSONResponse(status:)` whichever of the two annotations named the status,
which is tracked as a defect in https://github.com/swift-wire/wire-open-api/issues/89.

#### Scenario: a non-200 success inferred
- **WHEN** `createTask` (`POST /api/v1/tasks/new`) names no status and its document declares only `201` among its successes
- **THEN** the forwarder returns `.created(.init(body: .json(…)))`, and a valid `POST /api/v1/tasks/new` answers `201`

#### Scenario: one of two successes named
- **WHEN** `replaceTask` (`POST /api/v1/tasks/{id}/replace`) documents `200` and `201` and carries `@JSONResponse(status: .created)`
- **THEN** `POST /api/v1/tasks/9/replace?title=renamed` answers `201`

#### Scenario: two successes and no name
- **WHEN** `replaceTask` documents `200` and `201`, names no status, and returns its body alone
- **THEN** the generator exits 1 with `error: 'replaceTask' documents 2 success responses (.ok, .created), so which one the handler returns cannot be inferred. Name it with @JSONResponse(status:) or @ResponseStatus(_:), or return (status:body:) to choose one per call.`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `created` and `replaced` assertions). The diagnostics are pinned by nothing yet.

### Requirement: The selected response must be one the `@Operation` forwarder can construct
Against every response the handler can construct — the selected response, or each documented `2xx`
response when the handler returns its status in a response tuple — WireOpenAPIGen SHALL refuse a
body whose content types are not exactly `application/json` with
`error: '<id>' responds with <types>, which the typed shim cannot construct yet — it builds JSON bodies only. Use @RawOperation for this operation.`,
a response with a body whose handler returns nothing with
`error: '<id>' documents a <code> response with a body, but its handler returns nothing. Return the response body's type.`,
and a response with no content whose handler returns a value with
`error: '<id>' documents a <code> response with no content, but its handler returns <Type>. Drop the return, or document a body.`
For a response tuple, `<Type>` is the type of its `body` element. These three are reported at the
group's first controller's declaration line. A handler returning its status is checked for agreeing
successes first (see "A status tuple chooses among two or more documented successes that agree on a
body"), so for it only the content-type refusal can be reached here.

#### Scenario: a plain-text success
- **WHEN** `@Operation func getReport() async throws -> String` implements `getReport`, whose only success is `200` with `text/plain`
- **THEN** the generator exits 1 with `error: 'getReport' responds with text/plain, which the typed shim cannot construct yet — it builds JSON bodies only. Use @RawOperation for this operation.`

Pinned by: nothing yet.

### Requirement: Operation diagnostics are reported at the method's line and exit 1
Every refusal above SHALL be written to standard error as `<file>:<line>: error: <message>` and SHALL
end the run with exit status 1, writing no output file. A refusal found while scanning SHALL name the
scanned file and the line of the method or parameter. One found against the document SHALL name the
line of the operation's method where one is in hand and the controller's line otherwise. `<file>`
SHALL be the source file of the controller declaring the operation, found by its operationId, which
is unique in a group; it SHALL be the group's first controller's file only when no operation is in
hand.

#### Scenario: a group with nothing to refuse
- **WHEN** every operation a document declares is implemented by exactly one marked method whose form, bindings, body and status agree with the document
- **THEN** WireOpenAPIGen writes no diagnostic and the build succeeds

#### Scenario: a refusal in the second file of a group
- **WHEN** a document's group holds `OrderSummaryController` declared in `Controllers.swift` and `OrderController` declared in `OrderController.swift`, and the document refuses an operation implemented by `OrderController`'s method on line 58
- **THEN** the diagnostic begins `OrderController.swift:58: error:`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, `Build` step), `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (the shared `<file>:<line>: error:` shape). The owning controller's file in a group spanning files is pinned by nothing yet: `DiagnosticGoldenTool` lays out one controller file per case, and the behaviour was checked once by hand.

## ADDED Requirements

### Requirement: A typed operation may return a WireMVC response tuple
An `@Operation`'s return type SHALL be read as a response tuple when it is a tuple of more than one
element and at least one element is labelled `status`, `headers` or `body`. Its labels SHALL be one of
`(status:body:)`, `(status:headers:body:)`, `(status:headers:)` or `(headers:body:)`, in that order,
and any other labelling SHALL be refused while scanning with
`error: the response tuple returned by @Operation '<id>' is labelled (<labels>), which is not a response shape — write one of (status:body:), (status:headers:body:), (status:headers:) or (headers:body:).`
Elements SHALL be recognised by label only, never by type. The `body` element's type is the
handler's body type. A tuple without `status` SHALL answer with the response chosen as for a body
returned alone. WireMVC routes are unaffected and keep their own tuple shapes.

#### Scenario: find-or-create
- **WHEN** an operation at `POST /api/v1/tasks/register?id=<id>` documents `200` with an optional `ETag` header and `201` with a required `Location` header, both with a JSON task body, and its handler returns `(.created, [.location: "/api/v1/tasks/<id>"], task)` for an id it has not seen and `(.ok, [.eTag: "\"<id>\""], task)` for one it has
- **THEN** registering `r1` twice answers `201` with `Location: %2Fapi%2Fv1%2Ftasks%2Fr1`, then `200` with `ETag: %22r1%22`, both with the body `{"id":"r1","title":"registered r1"}` when the handler titles the task `registered <id>`

#### Scenario: a bodiless choice
- **WHEN** an operation at `POST /api/v1/tasks/{id}/touch` documents `202` and `204` with no content, and its handler returns `(status:headers:)` with `.accepted` for the id `later` and `.noContent` otherwise
- **THEN** `POST /api/v1/tasks/9/touch` answers `204` and `POST /api/v1/tasks/later/touch` answers `202`

#### Scenario: headers without a choice
- **WHEN** an operation at `GET /api/v1/tasks/{id}/version` documents only `200`, with a required `ETag` header and a JSON task body, and its handler returns `(headers:body:)` with `ETag` set to `"v1-<id>"`
- **THEN** `GET /api/v1/tasks/9/version` answers `200` with `ETag: %22v1-9%22`

#### Scenario: labels out of order
- **WHEN** an `@Operation` named `opA` returns `(body: String, status: Operations.OpA.SuccessStatus)`
- **THEN** the generator exits 1 with `error: the response tuple returned by @Operation 'opA' is labelled (body:status:), which is not a response shape — write one of (status:body:), (status:headers:body:), (status:headers:) or (headers:body:).`

Pinned by: `.github/workflows/build.yml` (probes `registeredNew`, `registeredAgain`, `touchedNow`, `touchedLater`, `versioned`), `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`tuple/not-a-response-shape`).

### Requirement: A status tuple chooses among two or more documented successes that agree on a body
For an `@Operation` returning a response tuple with `status`, WireOpenAPIGen SHALL refuse, in this
order: a `@JSONResponse(status:)` or `@ResponseStatus(_:)` on the same method with
`error: '<id>' returns its status in a response tuple and also names one with @<Annotation>(<status>). The two contradict each other — drop the annotation, or return the body alone.`;
fewer than two documented `2xx` responses with
`error: '<id>' returns its status in a response tuple, but documents only .<case>, so there is nothing to choose between. Return the body alone, or document the other successes.`
(`no success response` in place of `only .<case>` when there are none, and `(headers:body:)` in
place of `the body alone` when the tuple returns headers); and, after the status type is checked, a
documented success whose having a body differs from whether the tuple has a `body` element with
`error: '<id>' returns its status in a response tuple with a body, but its documented <code> success carries none. Every success a response tuple can answer with has to agree on whether it carries a body — document them alike, or use @RawOperation.`
(`without` and `one` in place of `with` and `none` for the converse).

#### Scenario: one success leaves no choice
- **WHEN** an operation `opA` documents only `200`, and its `@Operation` returns `(status: Operations.OpA.SuccessStatus, body: String)` with an enum declaring `case ok`
- **THEN** the generator exits 1 with `error: 'opA' returns its status in a response tuple, but documents only .ok, so there is nothing to choose between. Return the body alone, or document the other successes.`

#### Scenario: an annotation beside the tuple
- **WHEN** an operation `opA` documents `200` and `201`, and its `@Operation`, also carrying `@JSONResponse(status: .created)`, returns `(status: Operations.OpA.SuccessStatus, body: String)`
- **THEN** the generator exits 1 with `error: 'opA' returns its status in a response tuple and also names one with @JSONResponse(status: .created). The two contradict each other — drop the annotation, or return the body alone.`

#### Scenario: a bodiless success beside a bodied one
- **WHEN** an operation `opA` documents `200` with a JSON body and `204` with none, and its `@Operation` returns `(status: Operations.OpA.SuccessStatus, body: String)` with an enum declaring `ok` and `noContent`
- **THEN** the generator exits 1 with `error: 'opA' returns its status in a response tuple with a body, but its documented 204 success carries none. Every success a response tuple can answer with has to agree on whether it carries a body — document them alike, or use @RawOperation.`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`tuple/status-with-one-success`, `tuple/status-beside-an-annotation`, `tuple/successes-disagree-on-a-body`).

### Requirement: A tuple's status is an author-declared enum of exactly the documented successes
A response tuple's `status` element SHALL name an enum declared in the sources WireOpenAPIGen reads
for the run, conventionally as `extension Operations.<Operation> { enum SuccessStatus: Sendable,
Hashable, CaseIterable { … } }`, which may live in the controller's own module. The written type
SHALL be resolved by its nesting path: a leading component naming a module of the run is dropped,
and the rest SHALL match exactly one declaration's path or the end of it. Its cases SHALL be exactly
the operation's documented `2xx` responses, named by `GeneratorStatusNames.safeName(for:)`, in any
order. WireOpenAPIGen SHALL refuse, after the success count is checked:
a type naming no declaration with
`error: '<id>' returns its status in a response tuple as '<written>', which names no enum declared in the sources this build reads. The status has to be an enum of the documented successes. Declare `extension <namespace> { enum SuccessStatus: Sendable, Hashable, CaseIterable { case <a>; case <b> } }` and return `status: <namespace>.SuccessStatus`.`;
a type matching several with
`error: '<id>' returns its status in a response tuple as '<written>', which matches <n> enum declarations in the sources this build reads. Qualify it, as `<namespace>.SuccessStatus`, so it names one.`;
an enum with associated values with
`error: '<id>' returns its status in a response tuple as '<written>', whose cases carry associated values the generated response has nowhere to put. Its cases must be plain: <cases>.`;
and cases differing from the documented successes with
`error: '<id>' returns its status in a response tuple as '<written>', whose cases must be exactly the operation's documented successes (<cases>). It declares <extra>, which the document does not, and omits <missing>, which the document declares.`
(either clause alone when only one applies). `<namespace>` is `Operations.<Name>` with `<Name>`
from the operationId under the document's naming strategy. A typealias to the enum is not resolved.

#### Scenario: an enum that is not declared
- **WHEN** an operation `opA` documents `200` and `201`, and its `@Operation` returns `(status: Operations.OpA.SuccessStatus, body: String)` with no such enum in any source
- **THEN** the generator exits 1 with `error: 'opA' returns its status in a response tuple as 'Operations.OpA.SuccessStatus', which names no enum declared in the sources this build reads. The status has to be an enum of the documented successes. Declare `extension Operations.OpA { enum SuccessStatus: Sendable, Hashable, CaseIterable { case ok; case created } }` and return `status: Operations.OpA.SuccessStatus`.`

#### Scenario: cases that differ from the document
- **WHEN** an operation `opA` documents `200` and `201`, and its `@Operation` returns `(status: Operations.OpA.SuccessStatus, body: String)` with that enum declaring `ok` and `accepted`
- **THEN** the generator exits 1 with `error: 'opA' returns its status in a response tuple as 'Operations.OpA.SuccessStatus', whose cases must be exactly the operation's documented successes (.ok, .created). It declares .accepted, which the document does not, and omits .created, which the document declares.`

#### Scenario: the documented successes exactly
- **WHEN** an operation `opA` documents `200` with an optional `ETag` header and `201` with a required `Location` header, both with JSON bodies, and its `@Operation` returns `(status: Operations.OpA.SuccessStatus, headers: HTTPFields, body: String)` with that enum declaring `ok` and `created`
- **THEN** WireOpenAPIGen exits 0 and writes nothing to standard error

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`tuple/status-enum-not-declared`, `tuple/status-enum-cases-differ`, `accepted/status-tuple-over-two-successes`). The ambiguous and associated-value refusals are pinned by nothing yet.

### Requirement: `HTTPResponse.Status` as a tuple's status is refused with the enum to declare
A response tuple's `status` element written as any spelling ending in `HTTPResponse.Status`, such as
`HTTPResponse.Status` or `HTTPTypes.HTTPResponse.Status`, SHALL be refused, after the success count
is checked, with
`error: '<id>' returns its status in a response tuple as '<written>', which would let the handler answer with a status its document does not declare. Return an enum of the documented successes instead. Declare `extension <namespace> { enum SuccessStatus: Sendable, Hashable, CaseIterable { case <a>; case <b> } }` and return `status: <namespace>.SuccessStatus`.`

#### Scenario: a WireMVC route's status type
- **WHEN** an operation `opA` documents `200` and `201`, and its `@Operation` returns `(status: HTTPResponse.Status, body: String)`
- **THEN** the generator exits 1 with `error: 'opA' returns its status in a response tuple as 'HTTPResponse.Status', which would let the handler answer with a status its document does not declare. Return an enum of the documented successes instead. Declare `extension Operations.OpA { enum SuccessStatus: Sendable, Hashable, CaseIterable { case ok; case created } }` and return `status: Operations.OpA.SuccessStatus`.`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`tuple/status-is-an-http-response-status`).

### Requirement: The forwarder switches exhaustively over the status enum
For a response tuple with `status`, the generated forwarder SHALL switch over the returned status
with one `case .<name>:` per documented `2xx` response, in document order, each returning that
response's generated `Output` case, and with no `default`. No error SHALL be thrown for a status. A
status the document does not declare SHALL therefore fail to compile in the handler, since the enum
has no case for it.

#### Scenario: an undocumented status in the handler
- **WHEN** an operation documents `200` and `201`, its status enum `Operations.RegisterTask.SuccessStatus` declares `ok` and `created`, and its handler returns `.accepted` as the status
- **THEN** the build fails with `type 'Operations.RegisterTask.SuccessStatus' has no member 'accepted'`

#### Scenario: an enum declared in the controller's library
- **WHEN** a controller in a library module declares a status-tuple operation and a `public` status enum, and the conformer is generated into the app module depending on it
- **THEN** the app builds, and its forwarder switches over the library's enum

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, `Build` step) builds the exhaustive switch for an enum declared in the conformer's module. The compile-time refusal of an undocumented status, and the enum declared in another module, are pinned by nothing yet: the package has no harness asserting a build fails, and both were checked once by hand.

### Requirement: Returned header fields fill the chosen response's declared headers
For a response tuple with `headers`, the forwarder SHALL build each declared header of the chosen
response from the returned `HTTPFields`, matching names case-insensitively, as the generated
`Headers` member named by `GeneratorSafeNames.swiftMemberName(for:strategy:)`, in document order. An
optional header the fields omit SHALL be nil. WireOpenAPIGen SHALL refuse a declared header whose
schema is not a plain `string` (no `format`, no `enum`) when the handler returns fields, with
`error: '<id>' returns header fields, but its <code> response declares '<name>' with a schema other than a plain string, which the typed shim cannot build from a field value. Use @RawOperation for this operation.`,
and a required header when the handler returns no fields, with
`error: '<id>' documents a <code> response with the required header '<name>', but its handler returns no header fields. Return <shape> and set it.`
(`<shape>` is `(status:headers:body:)`, `(status:headers:)` or `(headers:body:)` as fits the handler).
The generated serializer writes a header value with URI coding, so `/` and `"` in a returned value go
out as `%2F` and `%22`.

#### Scenario: a header the shim cannot build
- **WHEN** an operation `opA` documents `200` with an `X-Count` header of schema `type: integer` and `201`, both with JSON bodies, and its `@Operation` returns `(status: Operations.OpA.SuccessStatus, headers: HTTPFields, body: String)`
- **THEN** the generator exits 1 with `error: 'opA' returns header fields, but its 200 response declares 'X-Count' with a schema other than a plain string, which the typed shim cannot build from a field value. Use @RawOperation for this operation.`

#### Scenario: a required header with no fields returned
- **WHEN** an operation `opA` documents `200` and `201` with a required `Location` header, both with JSON bodies, and its `@Operation` returns `(status: Operations.OpA.SuccessStatus, body: String)`
- **THEN** the generator exits 1 with `error: 'opA' documents a 201 response with the required header 'Location', but its handler returns no header fields. Return (status:headers:body:) and set it.`

#### Scenario: a field read whatever its case
- **WHEN** the returned fields carry `ETag` and the response declares `ETag`, read under the spelling `ETAG`
- **THEN** the value is the field's

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`tuple/header-the-shim-cannot-build`, `tuple/required-header-not-returned`), `Tests/WireOpenAPITests/ResponseSelectionTests.swift` (`readsDeclaredHeader`, `optionalAbsentIsNil`, `declaredFieldsPass`), `.github/workflows/build.yml` (probes `registeredNew`, `registeredAgain`, `versioned`).

### Requirement: A returned header the response does not describe answers 500 with no body
The forwarder SHALL throw `WireOpenAPIUndocumentedResponse` when the returned fields name a header
the chosen response does not declare, with `reason` `.undeclaredHeader(<canonical name>)`, and when
they omit one it declares as required, with `reason` `.missingHeader(<name>)`. The error SHALL carry
the operationId and the chosen response's status, SHALL have `httpStatus` `.internalServerError` and
a nil `httpBody`, and SHALL be rethrown ahead of every `@ErrorResponse` clause in the forwarder of an
operation returning header fields, so no author mapping answers it there.

#### Scenario: a stray field beside a catch-all
- **WHEN** a find-or-create operation maps `Swift.Error` to its documented `400`, and its handler returns `.created` with `Location` and an undeclared `Cache-Control` field for one id, and throws an ordinary error for another
- **THEN** the first answers `500` with a zero-length body and the second answers `400`

#### Scenario: a required header left out
- **WHEN** the response being built declares `Location` as required and the returned fields omit it
- **THEN** `WireOpenAPIUndocumentedResponse` is thrown with `reason` `.missingHeader("Location")`

Pinned by: `Tests/WireOpenAPITests/ResponseSelectionTests.swift` (`undocumentedIs500`, `requiredAbsentThrows`, `undeclaredFieldThrows`), `.github/workflows/build.yml` (probes `undocumentedHeader`, `refused`).
