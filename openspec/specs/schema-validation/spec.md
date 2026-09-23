# Schema validation

## Purpose

How the assertions an OpenAPI document makes, and swift-openapi-generator drops, are enforced at run
time. WireOpenAPIGen reads each schema's assertions, emits a per-document `Validation` enum of
validators that call the runtime checks in `WireOpenAPIValidate`, and calls them from each operation's
forwarder before the handler runs. A violated request throws `WireOpenAPIRequestValidationError`; a
violated response, when the document opts in, throws `WireOpenAPIResponseValidationError`. An
assertion the adapter cannot check fails the build.

Rationale: [WireOpenAPIValidation](../../../Proposals/WireOpenAPIValidation.md).
Documentation: [SchemaValidation](../../../Sources/WireOpenAPI/WireOpenAPI.docc/SchemaValidation.md).

## Requirements

### Requirement: One `Validation` enum per document, emitted only when something asserts
WireOpenAPIGen SHALL emit, inside the document's generated namespace, an `enum Validation` containing
one `static func schema_<Name>(_ value: Components.Schemas.<Name>?, at path: String, in location:
WireOpenAPIFailureLocation, into wireOpenAPIFailures: inout WireOpenAPIFailureAccumulator)` per
reachable component schema that carries a check, and one `static func <member>(_ input: <Input>) throws`, named by the operationId's safe member
name, per operation whose request carries a check. When no operation of the document
asserts anything, WireOpenAPIGen SHALL emit no `Validation` enum and no validation call.

#### Scenario: a recursive constrained schema
- **WHEN** the document's `Task` schema bounds `title` with `minLength: 1` and `maxLength: 40` and declares `subtasks` as an array of `$ref: '#/components/schemas/Task'`, and `createTask` takes a `Task` body
- **THEN** `Validation` declares `schema_Task` and `createTask(_:)`, and a request whose `subtasks[1].title` is empty is refused naming `body.subtasks[1].title`

#### Scenario: an unconstrained document
- **WHEN** no parameter, request body or checked response schema of any operation carries `minLength`, `maxLength`, `pattern`, a numeric bound, `multipleOf`, `minItems`, `maxItems` or `uniqueItems`
- **THEN** the generated file declares no `enum Validation` and no forwarder contains a `try Validation.` line

Pinned by: `.github/workflows/build.yml` (job "Fixtures — serve and probe", step "Serve an OpenAPI operation and a @Get route from one router", probe `assertNested`).

### Requirement: The operation validator runs first in the forwarder
The forwarder of an operation whose request carries a check SHALL begin with `try
Validation.<operationId>(input)`, before the request body is unwrapped, before any graph-aware
binding is resolved and before the handler is called, and inside the `do` that carries the
operation's `@ErrorResponse` clauses when it has any. It SHALL be emitted for `@RawOperation` and
`@Operation` alike.

#### Scenario: a raw operation with a path `pattern`
- **WHEN** `getTask` is a `@RawOperation` whose `id` path parameter declares `pattern: '^[a-z0-9-]+$'` and maps `WireOpenAPIRequestValidationError` to its documented 422
- **THEN** `GET /api/v1/tasks/NOT-LOWERCASE` answers `422` with the body `{"message":"invalid: path.id"}` and the handler is not called

Pinned by: `.github/workflows/build.yml` (job "Fixtures — serve and probe", probe `assertMapped`).

### Requirement: String assertions count code points and match patterns unanchored
`WireOpenAPIValidate.string` SHALL measure `minLength` and `maxLength` against
`value.unicodeScalars.count`, and SHALL treat `pattern` as a find anywhere in the value, so a pattern
constrains the whole string only when it anchors itself with `^` and `$`. A failure SHALL record the
keyword, the bound or pattern source as `expected`, and the measured length or the value as `actual`.

#### Scenario: a flag emoji
- **WHEN** `🇦🇺`, one `Character` made of two Unicode scalars, is checked against `maxLength: 1`
- **THEN** one failure with keyword `maxLength` and `actual` `2` is recorded

#### Scenario: an unanchored pattern
- **WHEN** `abc123` is checked against `pattern: [0-9]+`, and again against `pattern: ^[0-9]+$`
- **THEN** the first records nothing and the second records one `pattern` failure

Pinned by: `Tests/WireOpenAPITests/ValidationChecksTests.swift` (`lengthCountsScalars`, `patternIsAFind`, `severalAtOnce`).

### Requirement: Integer bounds are exact and number bounds tolerate binary rounding
`WireOpenAPIValidate.integer` SHALL accept any `BinaryInteger` width and compare `minimum`,
`maximum` and `multipleOf` exactly in `Int64`. `WireOpenAPIValidate.number` SHALL accept any
`BinaryFloatingPoint` width, compare in `Double`, and treat a `multipleOf` remainder within
`abs(multipleOf) * 1e-9` of zero or of the divisor as divisible. An exclusive bound SHALL reject the
bound itself and SHALL record `exclusiveMinimum` or `exclusiveMaximum` as its keyword.

#### Scenario: `multipleOf: 0.1`
- **WHEN** a `type: number` value of `0.3` is checked against `multipleOf: 0.1`
- **THEN** no failure is recorded, while `0.25` records `multipleOf`

#### Scenario: an exclusive minimum
- **WHEN** an integer value equal to its `minimum` is checked with `exclusiveMinimum: true`
- **THEN** one failure with keyword `exclusiveMinimum` is recorded

Pinned by: `Tests/WireOpenAPITests/ValidationChecksTests.swift` (`exclusiveBounds`, `widthsAreAccepted`, `multipleOfTolerance`).

### Requirement: Array assertions check the collection, then walk its elements
`WireOpenAPIValidate.array` SHALL check `minItems`, `maxItems` and `uniqueItems` on the array, then
call the emitted element closure for each element with the path `<path>[<index>]`, stopping once the
accumulator is full. `uniqueItems` SHALL be checked by comparing the count of distinct elements with
the array's count.

#### Scenario: a failing element
- **WHEN** `["ok", "x", "fine"]` at `query.tags` is checked with an element closure asserting `minLength: 2`
- **THEN** the one failure's path is `query.tags[1]`

Pinned by: `Tests/WireOpenAPITests/ValidationChecksTests.swift` (`uniqueItems`, `elementPathsAreIndexed`).

### Requirement: A nil value is never a failure
Every `WireOpenAPIValidate` check SHALL return without recording when the value is nil, leaving
absence to the generator's `required` handling.

#### Scenario: an absent optional query parameter
- **WHEN** `WireOpenAPIValidate.string(nil, …, minLength: 3, …)` is called
- **THEN** the accumulator stays empty

Pinned by: `Tests/WireOpenAPITests/ValidationChecksTests.swift` (`nilPasses`).

### Requirement: Objects, `allOf` and `$ref` are walked by emitted code
The emitted checks SHALL descend into an inline object's properties with the path
`<path>.<propertyName>`, SHALL check each `allOf` member through its `value<N>` accessor while
reporting at the parent's JSON path, and SHALL emit a `$ref` to a schema that carries checks as a
call to that schema's `schema_<Name>` function rather than an expansion, so a recursive schema emits
one self-calling function.

#### Scenario: a failure two levels into a recursive body
- **WHEN** `POST /api/v1/tasks/new?title=t` carries `{"id":"x","title":"ok","subtasks":[{"id":"y","title":"fine"},{"id":"z","title":""}]}`
- **THEN** the answer is `422` with the body `{"message":"rejected: body.subtasks[1].title"}`

Pinned by: `.github/workflows/build.yml` (job "Fixtures — serve and probe", probe `assertNested`).

### Requirement: Keywords the generator already enforces emit nothing
A schema carrying `enum` SHALL produce no check, and WireOpenAPIGen SHALL emit no check for
`required` or `additionalProperties: false`; the generated types and their `init(from:)` enforce them.

#### Scenario: an enum string with a `maxLength`
- **WHEN** a parameter's schema declares `enum: [a, b]` and `maxLength: 1`
- **THEN** the parameter's assertions are `.none` and no check is emitted for it

Pinned by: nothing yet.

### Requirement: An assertion the adapter cannot check fails the build
WireOpenAPIGen SHALL fail with an error naming the JSON path, the side, the operation and the
keywords when a request-reachable schema declares `minProperties` above its `required` count,
`maxProperties`, `minLength`/`maxLength`/`pattern` on a `format: date-time` string, or any assertion
beneath a `oneOf`/`anyOf` member. The message SHALL be `'<path>' in <side> '<operationId>' declares
<keywords>, which this adapter cannot check because <reason>. Remove it from the document, or check it
in the handler. @RawOperation is not an escape — validation is emitted for those too, from the same
document.`

#### Scenario: `minLength` on a date-time query parameter
- **WHEN** operation `opA`'s query parameter `q` declares `format: date-time` and `minLength`
- **THEN** WireOpenAPIGen reports `'query.q' in the request of 'opA' declares `minLength`, which this adapter cannot check because the generator emits `format: date-time` as a Foundation.Date, not a String. Remove it from the document, or check it in the handler. @RawOperation is not an escape — validation is emitted for those too, from the same document.`

#### Scenario: a property-count bound on a body
- **WHEN** `opA`'s body schema declares `minProperties` greater than the number of its `required` properties
- **THEN** WireOpenAPIGen reports `'body' in the request of 'opA' declares `minProperties`, which this adapter cannot check because a generated struct has a fixed set of members and no runtime property count. …`

#### Scenario: an assertion beneath a `oneOf`
- **WHEN** `opA`'s body is a `oneOf` whose first member asserts something
- **THEN** WireOpenAPIGen reports `'body' in the request of 'opA' declares assertions beneath member 1, which this adapter cannot check because the generator emits a oneOf/anyOf as an enum whose case names this adapter does not derive. …`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`parameters/assertion-on-a-type-the-format-changed`, `schemas/property-count-bounds`, `schemas/assertion-beneath-a-oneOf`), `.github/workflows/build.yml` (step "Check the diagnostics WireOpenAPIGen rejects with").

### Requirement: A pattern Swift cannot compile fails the build
WireOpenAPIGen SHALL compile every reachable `pattern` with Swift's `Regex` and SHALL fail with
`'<path>' in <side> '<operationId>' declares `pattern: <pattern>`, which Swift's regular-expression
engine cannot compile. JSON Schema patterns are ECMA-262; most translate directly, but this one does
not. Rewrite it, or remove it and check it in the handler.` when it does not compile.

#### Scenario: an unterminated class
- **WHEN** `opA`'s query parameter `q` declares `pattern: '[a-'`
- **THEN** WireOpenAPIGen reports `'query.q' in the request of 'opA' declares `pattern: [a-`, which Swift's regular-expression engine cannot compile. JSON Schema patterns are ECMA-262; most translate directly, but this one does not. Rewrite it, or remove it and check it in the handler.`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`parameters/pattern-swift-cannot-compile`).

### Requirement: Failures are collected up to a cap of 100
`WireOpenAPIFailureAccumulator` SHALL record every failure up to its limit, which defaults to
`WireOpenAPIFailureAccumulator.defaultLimit` (100), SHALL set `truncated` when a failure arrives after
the limit is reached, and SHALL yield no error when nothing was recorded. The generated walk SHALL
stop descending once `isFull` is true.

#### Scenario: ten failures against a limit of three
- **WHEN** ten failures are recorded into an accumulator built with `limit: 3`
- **THEN** it holds three, `truncated` and `isFull` are true, and `requestError(operationID:)?.truncated` is true

Pinned by: `Tests/WireOpenAPITests/SchemaValidationTests.swift` (`capIsEnforcedAndReported`, `underCapIsNotTruncated`, `emptyIsNotAnError`).

### Requirement: The request error answers 400 for a parameter failure and 422 otherwise
`WireOpenAPIRequestValidationError.httpStatus` SHALL be `.badRequest` when any failure's location is
`.path`, `.query` or `.header`, and `.unprocessableContent` when every failure is in `.body`.

#### Scenario: an unmapped path-parameter violation
- **WHEN** `deleteTask`'s `id` declares `maxLength: 8`, nothing maps the validation error, and `POST /api/v1/tasks/far-too-long-to-be-an-id/delete` arrives
- **THEN** the answer is `400`

#### Scenario: a body failure and a query failure together
- **WHEN** one error carries a `.body` failure and a `.query` failure, in either order
- **THEN** its status is `400`

Pinned by: `Tests/WireOpenAPITests/SchemaValidationTests.swift` (`bodyIs422`, `parameterIs400`, `mixedPrefersParameter`), `.github/workflows/build.yml` (probes `assertUnmapped`, `assertUnmappedBody`).

### Requirement: The unmapped request error carries a sorted JSON body
Unmapped, `WireOpenAPIRequestValidationError` SHALL answer with `Content-Type: application/json` and
a body `{"errors":[{"actual":…,"expected":…,"keyword":…,"path":…}]}` encoded with sorted keys and
unescaped slashes, with `"truncated":true` present only when the accumulator truncated.

#### Scenario: one `minLength` failure
- **WHEN** the error carries `path: "body.title"`, `keyword: "minLength"`, `expected: "3"`, `actual: "ab"`
- **THEN** the body is exactly `{"errors":[{"actual":"ab","expected":"3","keyword":"minLength","path":"body.title"}]}`

#### Scenario: unmapped over the wire
- **WHEN** `replaceTask`, which maps no validation error, receives a body whose `title` is empty
- **THEN** the answer is `422` and its body contains `"keyword":"minLength"` and `"path":"body.title"`

Pinned by: `Tests/WireOpenAPITests/SchemaValidationTests.swift` (`unmappedBodyCarriesFailures`, `truncationAppearsOnlyWhenTrue`), `.github/workflows/build.yml` (probes `assertUnmapped`, `assertUnmappedBody`).

### Requirement: A body the deserializer refused becomes the same request error
`WireOpenAPIRequestValidationError.init?(decoding:operationID:)` SHALL convert a `DecodingError` into
one `.body` failure: `keyNotFound` as keyword `required` at the missing key's path, `valueNotFound` as
`required` with `actual` `null`, `typeMismatch` as `type` naming the expected type, and
`dataCorrupted` as `invalid` carrying the decoder's debug description. Paths SHALL be rendered from
`body` with indices in brackets. Any other error SHALL yield nil. The terminal SHALL apply this
conversion to a handler failure, unwrapping `ServerError.underlyingError`, so one mapping of
`WireOpenAPIRequestValidationError` answers both a decode rejection and a generated check.

#### Scenario: a missing required property inside an array
- **WHEN** a `keyNotFound` for `title` arrives with coding path `subtasks`, `1`
- **THEN** the failure's path is `body.subtasks[1].title` and its keyword is `required`

#### Scenario: both sides of the seam
- **WHEN** `createTask` receives `{"id":"x"}`, which the deserializer refuses, and separately `{"id":"x","title":""}`, which the generated check refuses
- **THEN** both answers are identical: `422` from the operation's one `@ErrorResponse(WireOpenAPIRequestValidationError.self, .unprocessableContent, …)`

Pinned by: `Tests/WireOpenAPITests/SchemaValidationTests.swift` (`keyNotFound`, `typeMismatch`, `dataCorrupted`, `indexedPath`, `othersAreNotConverted`), `.github/workflows/build.yml` (probes `assertBody`, `assertDecodeSeam`).

### Requirement: Response validation is opt-in per document
WireOpenAPIGen SHALL check handler output only when the `wire-openapi.yaml` beside the document sets
`validatesResponses: true`; absent the file or the key, no response check is emitted and no
response-only schema is walked for diagnostics. With it set, a response-reachable assertion the
adapter cannot check SHALL fail the build with `<side>` reading `the <code> response of`.

#### Scenario: an unrepresentable response assertion, checked
- **WHEN** `opA`'s 200 response body declares `minProperties` and `wire-openapi.yaml` says `validatesResponses: true`
- **THEN** WireOpenAPIGen reports `'body' in the 200 response of 'opA' declares `minProperties`, which this adapter cannot check because a generated struct has a fixed set of members and no runtime property count. …`

#### Scenario: the same document, unchecked
- **WHEN** the same document has no `wire-openapi.yaml`
- **THEN** it is accepted

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`responses/unrepresentable-when-responses-are-checked`, `responses/unrepresentable-when-they-are-not`).

### Requirement: A violating response answers 500 with no body
A response check SHALL throw `WireOpenAPIResponseValidationError`, whose `httpStatus` is
`.internalServerError` and whose `httpBody` is nil. With response validation on, the forwarder's
`do` SHALL rethrow it ahead of every `@ErrorResponse` clause, so no author mapping, catch-all
included, matches it there.

#### Scenario: a raw operation returning an over-long field
- **WHEN** the OrdersAPI document sets `validatesResponses: true`, bounds `Order.item` with `maxLength: 60`, and `getOrder` returns an 80-character `item` for `GET /api/v2/orders/toolong`
- **THEN** the answer is `500` with a zero-length body

Pinned by: `Tests/WireOpenAPITests/SchemaValidationTests.swift` (`responseIs500`), `.github/workflows/build.yml` (probe `badResponse`).

### Requirement: Response checks cover every way a response is built
With response validation on, WireOpenAPIGen SHALL check the value a typed `@Operation` returns before
wrapping it, SHALL check each JSON body of a documented response a `@RawOperation`'s `Output` carries,
matched with `if case .<status>(let wireOpenAPIPayload) = wireOpenAPIOutput`, and SHALL check the body
a three-argument `@ErrorResponse` closure builds before returning it.

#### Scenario: a raw operation's output
- **WHEN** `getOrder` is a `@RawOperation` and its document checks responses
- **THEN** its forwarder binds `wireOpenAPIOutput`, checks the `.ok` JSON body against `schema_Order`, and returns it only when nothing failed

Pinned by: `.github/workflows/build.yml` (probe `badResponse`).

## Related specifications

- [controller-collation](../controller-collation/spec.md)
- [operation-forms](../operation-forms/spec.md)
- [route-mounting](../route-mounting/spec.md)
- [document-reading](../document-reading/spec.md)
- [build-plugins-and-gen-cli](../build-plugins-and-gen-cli/spec.md)
- [error-mapping-and-scope](../error-mapping-and-scope/spec.md)
- [wire-mvc error-response-tiers](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/error-response-tiers/spec.md)
