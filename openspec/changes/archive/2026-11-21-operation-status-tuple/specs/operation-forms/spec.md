## MODIFIED Requirements

### Requirement: A single documented success is inferred, several must be named
An `@Operation` naming no status and not returning a status enum SHALL construct the operation's one
documented `2xx` response, and SHALL be refused when the document declares zero or several with
`error: '<id>' documents <n> success responses (<cases>), so which one the handler returns cannot be inferred. Name it with @JSONResponse(status:) or @ResponseStatus(_:), or return a status enum of them to choose one per call.`
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
- **THEN** the generator exits 1 with `error: 'replaceTask' documents 2 success responses (.ok, .created), so which one the handler returns cannot be inferred. Name it with @JSONResponse(status:) or @ResponseStatus(_:), or return a status enum of them to choose one per call.`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `created` and `replaced` assertions). The diagnostics are pinned by nothing yet.

### Requirement: The selected response must be one the `@Operation` forwarder can construct
Against every response the handler can construct — the selected response, or each documented `2xx`
response when the handler returns a status enum — WireOpenAPIGen SHALL refuse a body whose content
types are not exactly `application/json` with
`error: '<id>' responds with <types>, which the typed shim cannot construct yet — it builds JSON bodies only. Use @RawOperation for this operation.`,
a response with a body whose handler returns nothing with
`error: '<id>' documents a <code> response with a body, but its handler returns nothing. Return the response body's type.`,
and a response with no content whose handler returns a value with
`error: '<id>' documents a <code> response with no content, but its handler returns <Type>. Drop the return, or document a body.`
For a `(status:body:)` or `(headers:body:)` tuple, `<Type>` is the type of its `body` element, and a
bare status enum or bare generated `Headers` counts as returning no body. These three are reported
at the group's first controller's declaration line. A handler returning a status enum is checked for
agreeing successes first (see "A status enum chooses among two or more documented successes that
agree on a body"), so for it only the content-type refusal can be reached here.

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

### Requirement: A typed operation may return a status enum or its response's generated headers
An `@Operation`'s return type SHALL be read as a response tuple when it is a tuple of more than one
element and at least one element is labelled `status`, `headers` or `body`. Its labels SHALL be
`(status:body:)` or `(headers:body:)`, in that order. WireMVC's `(status:headers:body:)` and
`(status:headers:)` SHALL be read so they can be refused against the document (see "`HTTPResponse.Status`
and free header fields are refused with the type to write"), and any other labelling SHALL be refused
while scanning with
`error: the response tuple returned by @Operation '<id>' is labelled (<labels>), which is not a response shape — write (status:body:) or (headers:body:).`
Elements SHALL be recognised by label only, never by type, and the `body` element's type is the
handler's body type. Because Swift has no one-element labelled tuple, a return that is not a tuple
SHALL be read as a status when it is spelled as `HTTPResponse.Status` or names one or more enums
declared in the sources WireOpenAPIGen reads; as headers when it is spelled `Operations.….Output.….Headers`
or `Components.Responses.<Name>.Headers`, optionally module-qualified; and as the body otherwise.
WireMVC routes are unaffected and keep their own tuple shapes.

#### Scenario: find-or-create
- **WHEN** an operation at `POST /api/v1/tasks/register?id=<id>` documents `200` with an optional `ETag` header and `201` with a required `Location` header, both with a JSON task body, and its handler returns `(.created(.init(location: "/api/v1/tasks/<id>")), task)` for an id it has not seen and `(.ok(.init(eTag: "\"<id>\"")), task)` for one it has
- **THEN** registering `r1` twice answers `201` with `Location: %2Fapi%2Fv1%2Ftasks%2Fr1`, then `200` with `ETag: %22r1%22`, both with the body `{"id":"r1","title":"registered r1"}` when the handler titles the task `registered <id>`

#### Scenario: a bodiless choice returned bare
- **WHEN** an operation at `POST /api/v1/tasks/{id}/touch` documents `202` with a required integer `Retry-After` header and `204`, neither with content, and its handler returns `.accepted(.init(retryAfter: 30))` for the id `later` and `.noContent` otherwise
- **THEN** `POST /api/v1/tasks/9/touch` answers `204`, and `POST /api/v1/tasks/later/touch` answers `202` with `Retry-After: 30`

#### Scenario: headers without a choice
- **WHEN** an operation at `GET /api/v1/tasks/{id}/version` documents only `200`, with a required `ETag` header and a JSON task body, and its handler returns `(headers:body:)` with `ETag` set to `"v1-<id>"`
- **THEN** `GET /api/v1/tasks/9/version` answers `200` with `ETag: %22v1-9%22`

#### Scenario: bodiless headers returned bare
- **WHEN** an operation at `POST /api/v1/tasks/{id}/seen` documents only `204`, with a required integer `X-Seen-Count` header, and its handler returns that response's generated `Headers` with the count set to the id's length
- **THEN** `POST /api/v1/tasks/abc/seen` answers `204` with `X-Seen-Count: 3`

#### Scenario: labels out of order
- **WHEN** an `@Operation` named `opA` returns `(body: String, status: Operations.OpA.SuccessStatus)`
- **THEN** the generator exits 1 with `error: the response tuple returned by @Operation 'opA' is labelled (body:status:), which is not a response shape — write (status:body:) or (headers:body:).`

Pinned by: `.github/workflows/build.yml` (probes `registeredNew`, `registeredAgain`, `touchedNow`, `touchedLater`, `versioned`, `seen`), `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`tuple/not-a-response-shape`).

### Requirement: A status enum chooses among two or more documented successes that agree on a body
For an `@Operation` returning a status enum, in a tuple or bare, WireOpenAPIGen SHALL refuse, in this
order: a `@JSONResponse(status:)` or `@ResponseStatus(_:)` on the same method with
`error: '<id>' returns a status enum and also names a status with @<Annotation>(<status>). The two contradict each other — drop the annotation, or return without the status enum.`;
header fields beside the status (see "`HTTPResponse.Status` and free header fields are refused with
the type to write"); no documented `2xx` response with
`error: '<id>' returns a status enum, but documents no success response, so there is nothing to choose between. Document the successes it can answer with.`;
exactly one with
`error: '<id>' returns a status enum, but documents only .<case>, so there is nothing to choose between. Return <form>, or document the other successes.`,
where `<form>` is the one-response form that fits that response: `` `(headers: <Headers>, body: <Body>)` ``
or `` `<Headers>` `` when it declares headers, with or without a body, and `the body alone` or `nothing`
when it declares none; and, after the enum is checked, a documented success whose having a body
differs from whether the handler returns one with
`error: '<id>' returns a status enum with a body, but its documented <code> success carries none. Every success a status enum can answer with has to agree on whether it carries a body — document them alike, or use @RawOperation.`
(`without` and `one` in place of `with` and `none` for the converse).

#### Scenario: one success leaves no choice
- **WHEN** an operation `opA` documents only `200` with no headers, and its `@Operation` returns `(status: Operations.OpA.SuccessStatus, body: String)` with an enum declaring `case ok`
- **THEN** the generator exits 1 with `error: 'opA' returns a status enum, but documents only .ok, so there is nothing to choose between. Return the body alone, or document the other successes.`

#### Scenario: one bodiless success with headers
- **WHEN** an operation `opA` documents only `204`, with no content and a required integer `X-Count` header, and its `@Operation` returns `Operations.OpA.SuccessStatus` bare
- **THEN** the generator exits 1 with `error: 'opA' returns a status enum, but documents only .noContent, so there is nothing to choose between. Return `Operations.OpA.Output.NoContent.Headers`, or document the other successes.`

#### Scenario: no success at all
- **WHEN** an operation `opA` documents only `400`, and its `@Operation` returns `Operations.OpA.SuccessStatus` bare
- **THEN** the generator exits 1 with `error: 'opA' returns a status enum, but documents no success response, so there is nothing to choose between. Document the successes it can answer with.`

#### Scenario: an annotation beside the enum
- **WHEN** an operation `opA` documents `200` and `201`, and its `@Operation`, also carrying `@JSONResponse(status: .created)`, returns `(status: Operations.OpA.SuccessStatus, body: String)`
- **THEN** the generator exits 1 with `error: 'opA' returns a status enum and also names a status with @JSONResponse(status: .created). The two contradict each other — drop the annotation, or return without the status enum.`

#### Scenario: a bodiless success beside a bodied one
- **WHEN** an operation `opA` documents `200` with a JSON body and `204` with none, and its `@Operation` returns `(status: Operations.OpA.SuccessStatus, body: String)` with an enum declaring `ok` and `noContent`
- **THEN** the generator exits 1 with `error: 'opA' returns a status enum with a body, but its documented 204 success carries none. Every success a status enum can answer with has to agree on whether it carries a body — document them alike, or use @RawOperation.`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`tuple/status-with-one-success`, `tuple/status-with-one-headered-bodiless-success`, `tuple/status-with-no-success`, `tuple/status-beside-an-annotation`, `tuple/successes-disagree-on-a-body`).

### Requirement: A status enum is author-declared, with exactly the documented successes as its cases
A returned status SHALL name an enum declared in the sources WireOpenAPIGen reads for the run,
conventionally as `extension Operations.<Operation> { enum SuccessStatus: Sendable, Hashable { … } }`,
which may live in the controller's own module. The written type SHALL be resolved by its nesting path:
a leading component naming a module of the run is dropped, and the rest SHALL match exactly one
declaration's path or the end of it. A typealias to the enum is not resolved. Its case names SHALL be
exactly the operation's documented `2xx` responses, named by `GeneratorStatusNames.safeName(for:)`,
in any order. WireOpenAPIGen SHALL refuse, after the success count is checked:
a type naming no declaration with
`error: '<id>' returns its status as '<written>', which names no enum declared in the sources this build reads. The status has to be an enum of the documented successes. Declare `extension <namespace> { enum SuccessStatus: Sendable, Hashable { <cases> } }` and return <return>.`;
a type matching several with
`error: '<id>' returns its status as '<written>', which matches <n> enum declarations in the sources this build reads. Qualify it, as `<namespace>.SuccessStatus`, so it names one.`;
and case names differing from the documented successes with
`error: '<id>' returns its status as '<written>', whose cases must be exactly the operation's documented successes (<cases>). It declares <extra>, which the document does not, and omits <missing>, which the document declares.`
(either clause alone when only one applies). `<namespace>` is `Operations.<Name>`, with `<Name>` from
the operationId under the document's naming strategy. In `<cases>`, each success is written
`case <name>(<Headers>)` when its response declares headers and `case <name>` otherwise, joined by
`; `. `<return>` is `` `(status: <namespace>.SuccessStatus, body: <Body>)` `` for a handler with a
body and `` `<namespace>.SuccessStatus` `` for one without.

#### Scenario: an enum that is not declared
- **WHEN** an operation `opA` documents `200` and `201`, neither declaring headers, and its `@Operation` returns `(status: Operations.OpA.SuccessStatus, body: String)` with no such enum in any source
- **THEN** the generator exits 1 with `error: 'opA' returns its status as 'Operations.OpA.SuccessStatus', which names no enum declared in the sources this build reads. The status has to be an enum of the documented successes. Declare `extension Operations.OpA { enum SuccessStatus: Sendable, Hashable { case ok; case created } }` and return `(status: Operations.OpA.SuccessStatus, body: String)`.`

#### Scenario: cases that differ from the document
- **WHEN** an operation `opA` documents `200` and `201`, and its `@Operation` returns `(status: Operations.OpA.SuccessStatus, body: String)` with that enum declaring `ok` and `accepted`
- **THEN** the generator exits 1 with `error: 'opA' returns its status as 'Operations.OpA.SuccessStatus', whose cases must be exactly the operation's documented successes (.ok, .created). It declares .accepted, which the document does not, and omits .created, which the document declares.`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`tuple/status-enum-not-declared`, `tuple/status-enum-cases-differ`). The ambiguous refusal is pinned by nothing yet.

### Requirement: Each status case carries exactly its response's generated headers
A status enum's case for a documented success whose response declares headers SHALL carry exactly
one associated value, spelled as that response's generated `Headers` type:
`Components.Responses.<Name>.Headers` when the response is a reference to `components/responses`
(with `<Name>` from the component key under the document's naming strategy), and
`<namespace>.Output.<Case>.Headers` otherwise (with `<Case>` the case name with its first letter
uppercased). A leading module qualifier before `Operations` or `Components` SHALL be ignored, and
the compiler checks that the spelling denotes the type. A case for a response declaring no headers
SHALL carry nothing. A response whose headers are all optional still requires its case to carry
them. WireOpenAPIGen SHALL refuse a case carrying nothing for a headered response with
`error: '<id>' returns its status as '<written>', whose case .<name> carries no headers, but the documented <code> response declares the header '<header>'. Declare it as `case <name>(<Headers>)`.`
(`the headers '<a>', '<b>'` for several); a case carrying anything else with
`error: '<id>' returns its status as '<written>', whose case .<name> carries (<payload>), but the documented <code> response's headers are `<Headers>`. Declare it as `case <name>(<Headers>)`.`;
and a case carrying a payload for a response declaring no headers with
`error: '<id>' returns its status as '<written>', whose case .<name> carries a payload, but the documented <code> response declares no headers, so there is nothing for it to carry. Declare it as `case <name>`.`

#### Scenario: a headered response's case without its headers
- **WHEN** an operation `opA` documents `200` with an optional `ETag` header and `201` with a required `Location` header, and its status enum declares `ok(Operations.OpA.Output.Ok.Headers)` and a bare `created`
- **THEN** the generator exits 1 with `error: 'opA' returns its status as 'Operations.OpA.SuccessStatus', whose case .created carries no headers, but the documented 201 response declares the header 'Location'. Declare it as `case created(Operations.OpA.Output.Created.Headers)`.`

#### Scenario: another response's headers
- **WHEN** the same operation's status enum declares `ok(Operations.OpA.Output.Ok.Headers)` and `created(Operations.OpA.Output.Ok.Headers)`
- **THEN** the generator exits 1 with `error: 'opA' returns its status as 'Operations.OpA.SuccessStatus', whose case .created carries (Operations.OpA.Output.Ok.Headers), but the documented 201 response's headers are `Operations.OpA.Output.Created.Headers`. Declare it as `case created(Operations.OpA.Output.Created.Headers)`.`

#### Scenario: headers for a response that declares none
- **WHEN** an operation `opA` documents `200` and `201`, neither declaring headers, and its status enum declares `ok` and `created(Operations.OpA.Output.Created.Headers)`
- **THEN** the generator exits 1 with `error: 'opA' returns its status as 'Operations.OpA.SuccessStatus', whose case .created carries a payload, but the documented 201 response declares no headers, so there is nothing for it to carry. Declare it as `case created`.`

#### Scenario: every case as the document declares it
- **WHEN** an operation `opA` documents `200` with an optional `ETag` header and `201` with a required `Location` header, both with JSON bodies, and its `@Operation` returns `(status: Operations.OpA.SuccessStatus, body: String)` with that enum declaring `ok(Operations.OpA.Output.Ok.Headers)` and `created(Operations.OpA.Output.Created.Headers)`
- **THEN** WireOpenAPIGen exits 0 and writes nothing to standard error

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`tuple/case-without-its-headers`, `tuple/case-with-the-wrong-headers`, `tuple/case-with-headers-its-response-lacks`, `accepted/status-tuple-over-two-successes`).

### Requirement: Without a status, returned headers are exactly the one success's generated headers
For an `@Operation` returning no status, returned headers, in `(headers:body:)` or bare, SHALL be
spelled as the selected response's generated `Headers` type, named as for a status case, and the
selected response SHALL declare headers. A handler returning no headers SHALL be refused when the
selected response declares a required header, and accepted when its headers are all optional. WireOpenAPIGen SHALL refuse headers for a response declaring none with
`error: '<id>' returns headers, but its documented .<case> response declares none. Return <form>.`;
headers of another type with
`error: '<id>' returns its headers as '<written>', but its documented .<case> response's headers are `<Headers>`. Return <form>.`;
and no headers for a response with a required one with
`error: '<id>' documents a <code> response with the required header '<header>', but its handler returns no headers. Return <form> and set it.`,
with `<form>` the one-response form described in "A status enum chooses among two or more documented
successes that agree on a body".

#### Scenario: another response's headers without a status
- **WHEN** an operation `opA` documents only `201`, with a required `Location` header and a JSON body, and its `@Operation` returns `(headers: Operations.OpA.Output.Ok.Headers, body: String)`
- **THEN** the generator exits 1 with `error: 'opA' returns its headers as 'Operations.OpA.Output.Ok.Headers', but its documented .created response's headers are `Operations.OpA.Output.Created.Headers`. Return `(headers: Operations.OpA.Output.Created.Headers, body: String)`.`

#### Scenario: headers for a headerless response
- **WHEN** an operation `opA` documents only `200` with a JSON body and no headers, and its `@Operation` returns `(headers: Operations.OpA.Output.Ok.Headers, body: String)`
- **THEN** the generator exits 1 with `error: 'opA' returns headers, but its documented .ok response declares none. Return the body alone.`

#### Scenario: a required header with no headers returned
- **WHEN** an operation `opA` documents only `201`, with a required `Location` header and a JSON body, and its `@Operation` returns `String`
- **THEN** the generator exits 1 with `error: 'opA' documents a 201 response with the required header 'Location', but its handler returns no headers. Return `(headers: Operations.OpA.Output.Created.Headers, body: String)` and set it.`

#### Scenario: an integer header
- **WHEN** an operation `opA` documents only `200`, with a required integer `X-Count` header and a JSON body, and its `@Operation` returns `(headers: Operations.OpA.Output.Ok.Headers, body: String)`
- **THEN** WireOpenAPIGen exits 0 and writes nothing to standard error

#### Scenario: a referenced response
- **WHEN** an operation `opA` documents `201` as a reference to the component response `Located`, which declares a `Location` header and a JSON body, and its `@Operation` returns `(headers: Components.Responses.Located.Headers, body: String)`
- **THEN** WireOpenAPIGen exits 0 and writes nothing to standard error

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`tuple/headers-of-another-response`, `tuple/headers-for-a-headerless-response`, `tuple/required-header-not-returned`, `accepted/headers-of-any-schema`, `accepted/headers-of-a-referenced-response`), `.github/workflows/build.yml` (probes `versioned`, `seen`). That a referenced response's spelling compiles was checked once by hand, and is pinned by nothing yet.

### Requirement: `HTTPResponse.Status` and free header fields are refused with the type to write
A returned status spelled as anything ending in `HTTPResponse.Status`, such as `HTTPResponse.Status`
or `HTTPTypes.HTTPResponse.Status`, SHALL be refused, after the success count is checked, with
`error: '<id>' returns its status as '<written>', which would let the handler answer with a status its document does not declare. Return an enum of the documented successes instead. Declare `extension <namespace> { enum SuccessStatus: Sendable, Hashable { <cases> } }` and return <return>.`
WireMVC's `(status:headers:body:)` or `(status:headers:)` SHALL be refused, before the success count
is checked, with
`error: '<id>' returns header fields beside its status, but an operation's headers travel in its status enum: each case whose response declares headers carries them. Declare `extension <namespace> { enum SuccessStatus: Sendable, Hashable { <cases> } }` and return <return>.`
Headers returned without a status whose type's last component is `HTTPFields` SHALL be refused, when
the selected response declares headers, with
`error: '<id>' returns its headers as '<written>', which would let the handler send headers its document does not declare. Return <form> — the generated headers of its .<case> response.`
`<cases>`, `<return>` and `<form>` are as in the requirements above.

#### Scenario: a WireMVC route's status type
- **WHEN** an operation `opA` documents `200` with an optional `ETag` header and `201` with a required `Location` header, both with JSON bodies, and its `@Operation` returns `(status: HTTPResponse.Status, body: String)`
- **THEN** the generator exits 1 with `error: 'opA' returns its status as 'HTTPResponse.Status', which would let the handler answer with a status its document does not declare. Return an enum of the documented successes instead. Declare `extension Operations.OpA { enum SuccessStatus: Sendable, Hashable { case ok(Operations.OpA.Output.Ok.Headers); case created(Operations.OpA.Output.Created.Headers) } }` and return `(status: Operations.OpA.SuccessStatus, body: String)`.`

#### Scenario: WireMVC's header fields beside a status
- **WHEN** the same operation's `@Operation` returns `(status: Operations.OpA.SuccessStatus, headers: HTTPFields, body: String)`
- **THEN** the generator exits 1 with `error: 'opA' returns header fields beside its status, but an operation's headers travel in its status enum: each case whose response declares headers carries them. Declare `extension Operations.OpA { enum SuccessStatus: Sendable, Hashable { case ok(Operations.OpA.Output.Ok.Headers); case created(Operations.OpA.Output.Created.Headers) } }` and return `(status: Operations.OpA.SuccessStatus, body: String)`.`

#### Scenario: header fields without a status
- **WHEN** an operation `opA` documents only `201`, with a required `Location` header and a JSON body, and its `@Operation` returns `(headers: HTTPFields, body: String)`
- **THEN** the generator exits 1 with `error: 'opA' returns its headers as 'HTTPFields', which would let the handler send headers its document does not declare. Return `(headers: Operations.OpA.Output.Created.Headers, body: String)` — the generated headers of its .created response.`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`tuple/status-is-an-http-response-status`, `tuple/http-fields-beside-a-status`, `tuple/headers-as-http-fields`).

### Requirement: The forwarder passes the chosen response and its headers through unchecked
For a status enum, the generated forwarder SHALL switch over the returned status with one case per
documented `2xx` response, in status-code order, binding a headered case's payload and passing it as
the generated response's `headers:`, and with no `default`. For headers without a status, it SHALL
pass the returned headers as the selected response's `headers:`. No error SHALL be thrown, and no
header SHALL be read, converted or checked, at run time; only a body is checked, when response
validation is on, as for a body returned alone. A status or a header the document does not declare
SHALL therefore fail to compile in the handler: the enum has no case for the one, and the generated
`Headers` has no member for the other. A header of any schema SHALL be supplied as the type the
generator gives it.

#### Scenario: an undocumented status in the handler
- **WHEN** an operation documents `200` and `201`, its status enum `Operations.RegisterTask.SuccessStatus` declares `ok` and `created`, and its handler returns `.accepted` as the status
- **THEN** the build fails with `type 'Operations.RegisterTask.SuccessStatus' has no member 'accepted'`

#### Scenario: an undeclared header in the handler
- **WHEN** the same operation's `201` declares only `Location`, and its handler returns `.created(.init(location: "/tasks/1", cacheControl: "no-store"))`
- **THEN** the build fails with `extra argument 'cacheControl' in call`

#### Scenario: an enum declared in the controller's library
- **WHEN** a controller in a library module declares a status-choosing operation whose `201` declares a required `Location` and a required integer `X-Count`, beside a `public` status enum whose `created` case carries that response's generated `Headers`, and the conformer is generated into the app module depending on it
- **THEN** the app builds, and the operation answers `201` with both headers set

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, `Build` step, and probes `touchedLater`, `seen`) builds the exhaustive switch for an enum declared in the conformer's module and sends integer headers. The compile-time refusals of an undocumented status and an undeclared header, and the enum declared in another module, are pinned by nothing yet: the package has no harness asserting a build fails, and each was checked once by hand.
