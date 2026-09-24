# Document reading

## Purpose

How WireOpenAPIGen reads an OpenAPI document: which versions it accepts and through which model,
how it resolves references, and what it extracts for each `operationId` (method, path, parameters,
responses and request body). Everything the generator knows about an operation comes from the
document source file, never from swift-openapi-generator's emitted Swift. The per-document settings
read beside the document are specified where they take effect and linked below.

Rationale: [WireOpenAPIAdvanced](../../../Documentation/Notes/WireOpenAPIAdvanced.md), [WireOpenAPIValidation](../../../Proposals/WireOpenAPIValidation.md).

## Requirements

### Requirement: OpenAPI 3.0 documents are decoded by OpenAPIKit30 and converted
WireOpenAPIGen SHALL read the document's `openapi:` value first and, for `3.0.0`, `3.0.1`, `3.0.2`,
`3.0.3` and `3.0.4`, SHALL decode the document with `OpenAPIKit30` and convert it with
`convert(to: .v3_1_0)`, so the rest of the generator reads one OpenAPIKit 3.1 model.

#### Scenario: a 3.0.3 document
- **WHEN** the document passed as `--spec` begins `openapi: 3.0.3`
- **THEN** it is decoded as an `OpenAPIKit30.OpenAPI.Document` and read as its 3.1 conversion

Pinned by: nothing yet.

### Requirement: OpenAPI 3.1 and 3.2 documents are decoded by OpenAPIKit
For `openapi:` values `3.1.0`, `3.1.1`, `3.1.2` and `3.2.0`, WireOpenAPIGen SHALL decode the
document directly as an `OpenAPIKit.OpenAPI.Document`.

#### Scenario: the fixture's documents
- **WHEN** the Tasks and Orders documents declare `openapi: 3.1.0`
- **THEN** both are read and their operations are served

Pinned by: `Fixtures/Sources/WireOpenAPIBootstrapExample/openapi.yaml`, `Fixtures/Sources/OrdersAPI/openapi.yaml` (built and probed by the `Fixtures` job in `.github/workflows/build.yml`), `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (every case's document is `openapi: 3.1.0`).

### Requirement: A document with no `openapi:` version is a build error
When the file has no `openapi:` key, WireOpenAPIGen SHALL write
`<document>: error: the OpenAPI document has no `openapi:` version, so it cannot be read as an OpenAPI document.`
to standard error and exit with status 1.

#### Scenario: a YAML file that is not an OpenAPI document
- **WHEN** the file passed as `--spec` is `info: { title: X, version: 1.0.0 }` with no `openapi:` line
- **THEN** the generator exits 1 with `error: the OpenAPI document has no `openapi:` version, so it cannot be read as an OpenAPI document.`

Pinned by: nothing yet.

### Requirement: An unsupported `openapi:` version is a build error
When the `openapi:` value is none of the eight versions above, WireOpenAPIGen SHALL write
`<document>: error: the OpenAPI document declares `openapi: <version>`, which this adapter cannot read.`
to standard error and exit with status 1.

#### Scenario: a version newer than the adapter
- **WHEN** the document declares `openapi: 3.3.0`
- **THEN** the generator exits 1 with `error: the OpenAPI document declares `openapi: 3.3.0`, which this adapter cannot read.`

Pinned by: nothing yet.

### Requirement: A document the model cannot decode is a build error
When OpenAPIKit or OpenAPIKit30 throws while decoding a document of a supported version,
WireOpenAPIGen SHALL write `<document>: error: the OpenAPI document could not be read: <error>` to
standard error and exit with status 1.

#### Scenario: a malformed operation
- **WHEN** a `3.1.0` document has a `responses:` value that is a string
- **THEN** the generator exits 1 with a message beginning `error: the OpenAPI document could not be read:`

Pinned by: nothing yet.

### Requirement: References are resolved one hop at each read site
WireOpenAPIGen SHALL resolve a `$ref` against the Components Object with one lookup at each of the
places it reads: the path item, each parameter, each response, the request body, and a JSON content
entry. It SHALL NOT ask for a fully dereferenced document.

#### Scenario: a parameter declared by reference
- **WHEN** `summariseTask` declares its path parameter as `{ $ref: '#/components/parameters/TaskId' }` and the handler binds `@Path id: String`
- **THEN** the binding is accepted as a declared path parameter, and `GET /api/v1/tasks/9/summary` is served

Pinned by: `Fixtures/Sources/WireOpenAPIBootstrapExample/openapi.yaml` (`summariseTask`), `Fixtures/Sources/WireOpenAPIBootstrapExample/Controllers.swift` (`summariseTask`), `.github/workflows/build.yml` (`Fixtures` job, `Build` step, and the `typed` assertion of step `Serve an OpenAPI operation and a @Get route from one router`).

### Requirement: An unresolvable reference is a build error naming the document
When a one-hop lookup fails, WireOpenAPIGen SHALL write
`<document>: error: the OpenAPI document has <what> that could not be resolved: <error>` to standard
error and exit with status 1, where `<what>` names the site, for example
`a parameter reference in '<operationId>'` or `a path item reference for '<path>'`.

#### Scenario: a dangling parameter reference
- **WHEN** `getTask` declares `{ $ref: '#/components/parameters/Missing' }` and no such component exists
- **THEN** the generator exits 1 with a message beginning `error: the OpenAPI document has a parameter reference in 'getTask' that could not be resolved:`

Pinned by: nothing yet.

### Requirement: A schema `$ref` is kept as a name, not followed
When WireOpenAPIGen reads a schema's assertions and meets a `$ref`, it SHALL record the referenced
component schema's name and SHALL NOT follow the reference, so a recursive schema is read in finite
time. Every entry of `components.schemas` SHALL be read once, under its document name. A schema
reference with no component name SHALL fail with
`<document>: error: the OpenAPI document has a schema reference for <subject> this adapter cannot name: <reference>`
and exit status 1.

#### Scenario: a recursive component schema
- **WHEN** the Tasks document's `Task` declares `subtasks: { type: array, items: { $ref: '#/components/schemas/Task' } }`
- **THEN** the fixture builds, and a `POST /api/v1/tasks/new` whose second subtask has an empty title answers `422` with `"message":"rejected: body.subtasks[1].title"`

#### Scenario: a recursive schema in a dependency's document
- **WHEN** the Orders document's `Order` declares a `relatedOrders` array of `Order`
- **THEN** the fixture builds

Pinned by: `Fixtures/Sources/WireOpenAPIBootstrapExample/openapi.yaml` (`Task.subtasks`), `Fixtures/Sources/OrdersAPI/openapi.yaml` (`relatedOrders`), `.github/workflows/build.yml` (`Fixtures` job, `Build` step, and the `assertNested` probe).

### Requirement: Path-level parameters apply to every operation beneath them
For each operation, WireOpenAPIGen SHALL read the path item's `parameters` followed by the
operation's own `parameters` as that operation's declared parameters.

#### Scenario: an `id` declared on the path item
- **WHEN** `/tasks/{id}` declares `parameters: [{ name: id, in: path, required: true, schema: { type: string } }]` at path level and `getTask` declares none
- **THEN** a handler for `getTask` may bind `@Path id: String`

Pinned by: nothing yet.

### Requirement: Only path, query and header parameters are read
WireOpenAPIGen SHALL record a parameter's name, its location as `path`, `query` or `header`, and
its schema's assertions. A `cookie` parameter, or any other location, SHALL be left out of the
operation's declared parameters.

#### Scenario: a header parameter
- **WHEN** `summariseTask` declares `{ name: X-Request-Id, in: header }`
- **THEN** it is recorded with location `header`, read through `input.headers`

#### Scenario: a cookie parameter
- **WHEN** an operation declares `{ name: session, in: cookie }`
- **THEN** it is not among the operation's declared parameters

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, the `typed` assertion, for the header case). The cookie case is pinned by nothing yet.

### Requirement: Only single-status responses are read
WireOpenAPIGen SHALL read each response whose key is a single status code, with its content-type
keys sorted, and SHALL order the responses by status code. A `default` response and a range key
such as `2XX` SHALL be left out.

#### Scenario: a range key beside a concrete one
- **WHEN** an operation declares responses `'200'`, `'4XX'` and `default`
- **THEN** only `200` is among the operation's declared responses

#### Scenario: statuses out of order
- **WHEN** `deleteTask` declares `'500'`, `'202'` and `'204'` in that order
- **THEN** the responses are read as `202`, `204`, `500`

Pinned by: nothing yet.

### Requirement: The request body is read for requiredness and content types
When an operation declares a `requestBody`, WireOpenAPIGen SHALL read its `required` flag, its
content-type keys sorted, and the assertions of its `application/json` schema only.

#### Scenario: an optional body
- **WHEN** `replaceTask` declares a `requestBody` without `required: true`
- **THEN** the body is read as not required, and `POST /api/v1/tasks/9/replace?title=renamed` with and without a body are both served

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, the `replaced` and `replacedBare` assertions).

### Requirement: An operation without an `operationId` is not read
WireOpenAPIGen SHALL key each operation by its `operationId` and SHALL skip an operation that
declares none.

#### Scenario: an anonymous operation
- **WHEN** `/health` declares `get:` with no `operationId`
- **THEN** no route is derived for it

Pinned by: nothing yet.

## Related specifications

- [route-mounting](../route-mounting/spec.md), for how the document's `servers:` become the registration prefix
- [operation-forms](../operation-forms/spec.md), for how the declared parameters, responses and body are checked against handlers, and for `namingStrategy`
- [schema-validation](../schema-validation/spec.md), for the assertions read from schemas and `validatesResponses`
- [controller-collation](../controller-collation/spec.md)
- [build-plugins-and-gen-cli](../build-plugins-and-gen-cli/spec.md)
