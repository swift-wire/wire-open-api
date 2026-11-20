# Operation forms

## Purpose

The two ways a controller method implements an OpenAPI operation, and what WireOpenAPIGen checks
about each against the document. `@RawOperation` hands the method the generated `Input` and takes
back its `Output`; `@Operation` binds each parameter from the `Input` member the document places it
in, or from the request scope for a graph-aware binding, and wraps the return value in the response
the document declares. Both are forwarded to from the group's one generated `APIProtocol` conformer, and every operation the
document declares must be implemented by exactly one marked method.

Terms used below:

- **Group**: the controllers collated against one OpenAPI document; see
  [controller-collation](../controller-collation/spec.md).
- **Conformer**: the `Conformer` struct WireOpenAPIGen emits once per group, which conforms to the
  `APIProtocol` swift-openapi-generator derives from that document and holds one field per controller,
  optional for a request-scoped one. A **template** conformer is built once at registration with no
  request-scoped field filled; when the group has a request-scoped controller, a **per-request**
  conformer holding that request's subjects is built for each dispatch.
- **Forwarder**: the conformer's implementation of one `APIProtocol` requirement, which calls the
  marked method. A `@RawOperation` forwarder passes `Input` through; an `@Operation` forwarder reads
  each argument out of `Input` and wraps the result in `Output`.
- **Route terminal**: the generated route handler for one operation, which obtains the request's
  server and calls that operation's method on it; see [route-mounting](../route-mounting/spec.md).
- **Graph-aware binding**: an `@Operation` parameter whose value is produced by a worker resolved
  from the request scope rather than read from the request, defined below.

Rationale: [WireOpenAPIAdvanced](../../../Documentation/Notes/WireOpenAPIAdvanced.md).
Documentation: [Operations](../../../Sources/WireOpenAPI/WireOpenAPI.docc/Operations.md), [WritingAnOpenAPIController](../../../Sources/WireOpenAPI/WireOpenAPI.docc/WritingAnOpenAPIController.md).

## Requirements

### Requirement: The operation markers expand to nothing
`@RawOperation()`, `@RawOperation(_ operationID: String)`, `@Operation()` and
`@Operation(_ operationID: String)` SHALL be attached peer macros implemented by
`OpenAPIControllerMacro`, whose expansion returns no peers. What a marked method means SHALL be
decided by WireOpenAPIGen reading the source, not by the macro.

#### Scenario: a marked method compiles unchanged
- **WHEN** `TaskListController` declares `@RawOperation func listTasks(_ input: Operations.ListTasks.Input) async throws -> Operations.ListTasks.Output`, implementing `listTasks` (`GET /api/v1/tasks`) by answering `.ok` with the JSON array `["1", "2", "3"]`
- **THEN** the target builds with the method as written, and `GET /api/v1/tasks` answers `200` with a body containing `"3"`

Pinned by: `Sources/WireOpenAPI/OpenAPIController.swift` (the macro declarations), `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `list` assertion), `Tests/WireOpenAPIMacrosTests/OpenAPIControllerMacroTests.swift` (`testMarkerExpandsToNothing`, which pins that `OpenAPIControllerMacro` expands to nothing when attached as `@OpenAPIController` to a struct). No test attaches an operation marker to a method, so the empty expansion of the markers themselves is pinned by nothing yet.

### Requirement: The bare marker takes the method name as the operationId
WireOpenAPIGen SHALL take a method's operationId from the string literal passed to
`@RawOperation(_:)` or `@Operation(_:)` when one is given, and from the method's own name otherwise.

#### Scenario: the bare form
- **WHEN** `TaskController` declares a bare `@RawOperation func getTask(_ input: Operations.GetTask.Input)`, the document declares `getTask` as `GET /api/v1/tasks/{id}`, and the method answers `.ok` with a `Task` titled `task-<id> via <request path>`
- **THEN** it implements operationId `getTask`, and `GET /api/v1/tasks/42` answers `200` with a title of `task-42 via /api/v1/tasks/42`

#### Scenario: the declared form
- **WHEN** a controller declares `@RawOperation("get-task") func fetch(_ input: Operations.get_hyphen_task.Input) async throws -> Operations.get_hyphen_task.Output` under the `defensive` strategy, against a document declaring `get-task`
- **THEN** `get-task` counts as implemented by `fetch`, so it is not named by the every-operation-implemented error

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `openapi` assertion). The declared form is pinned by nothing yet.

### Requirement: The conformer names the requirement from the operationId and forwards to the method
The conformer SHALL implement the `APIProtocol` requirement named by the member name
[generator-naming](../generator-naming/spec.md) derives from the operationId, and forward it to the method by
the method's own name.

#### Scenario: a renamed method under the defensive strategy
- **WHEN** a controller declares `@RawOperation("get-task") func fetch(_ input: Operations.get_hyphen_task.Input) async throws -> Operations.get_hyphen_task.Output` under the `defensive` strategy
- **THEN** the conformer implements `get_hyphen_task(_:)` taking `Operations.get_hyphen_task.Input` and returning `Operations.get_hyphen_task.Output`, and forwards to `fetch`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, `Build` step) for methods whose name is the operationId. A renamed method is pinned by nothing yet.

### Requirement: The route terminal calls the generated server method by the method's own name
The route terminal SHALL call the server's `<methodName>(request:body:metadata:)` with the
author's method name, while `UniversalServer` names its per-operation methods from the operationId.
A declared-form method therefore builds only when its name equals
the member name [generator-naming](../generator-naming/spec.md) derives from the operationId; a renamed method fails to compile,
which is tracked as a defect in https://github.com/swift-wire/wire-open-api/issues/63.

#### Scenario: a renamed method
- **WHEN** a controller declares `@RawOperation("get-task") func fetch(_ input: Operations.get_hyphen_task.Input) async throws -> Operations.get_hyphen_task.Output` under the `defensive` strategy
- **THEN** the generated terminal calls the server's `fetch(request:body:metadata:)`, `UniversalServer` declares only `get_hyphen_task(request:body:metadata:)`, and the build fails

Pinned by: nothing yet.

### Requirement: `@RawOperation` takes one `Input` and returns its `Output`
A `@RawOperation` method SHALL declare exactly one parameter and a return type, and its forwarder
SHALL pass the generated `Input` through unchanged and return what the method returns. The
forwarder's signature SHALL copy the method's parameter and return types exactly as written.
Otherwise WireOpenAPIGen SHALL write
`<file>:<line>: error: @RawOperation '<id>' must take the operation's generated Input and return its Output — that is the shape the generated operation method dispatches to.`
at the method name's line and exit with status 1.

#### Scenario: types written qualified
- **WHEN** `OrderSummaryController` declares `@RawOperation func listOrders(_ input: OrdersAPI.Operations.ListOrders.Input) async throws -> OrdersAPI.Operations.ListOrders.Output`, implementing `listOrders` (`GET /api/v2/orders`) by answering `.ok` with `["item-7", "item-9"]`
- **THEN** the forwarder is declared with those spellings, and `GET /api/v2/orders` answers `200` with a body containing `"item-7"` and `"item-9"`

#### Scenario: a raw method with no return
- **WHEN** a controller declares `@RawOperation func getTask(_ input: Operations.GetTask.Input) async throws`
- **THEN** the generator exits 1 with `error: @RawOperation 'getTask' must take the operation's generated Input and return its Output — that is the shape the generated operation method dispatches to.`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `summary` assertion). The diagnostic is pinned by nothing yet.

### Requirement: Every `@Operation` parameter carries a binding annotation
Each parameter of an `@Operation` method SHALL carry `@Path`, `@Query`, `@Header`, `@JSONBody`, or
the attribute of a graph-aware binding (see "A `@RequestBinding` attribute marks a graph-aware
binding"). A parameter carrying none SHALL be refused with
`<file>:<line>: error: parameter '<name>' of @Operation '<id>' needs a binding annotation — one of @Path, @Query, @Header, @JSONBody. The document says where each parameter lives; the annotation says which one this is.`
at the parameter's line, and the generator SHALL exit with status 1. The message SHALL list only the
four built-in annotations, even when graph-aware bindings are declared in the scanned sources.

#### Scenario: a parameter left bare
- **WHEN** `@Operation func summariseTask(id: String) async throws -> Components.Schemas.Task` is declared
- **THEN** the generator exits 1 with `error: parameter 'id' of @Operation 'summariseTask' needs a binding annotation — one of @Path, @Query, @Header, @JSONBody. The document says where each parameter lives; the annotation says which one this is.`

Pinned by: nothing yet.

### Requirement: The document decides where a bound parameter is read from
For a `@Path`, `@Query` or `@Header` parameter, the documented name SHALL be the attribute's string
literal argument when given and the parameter's own name otherwise. The forwarder SHALL read it from
the `Input`'s `path`, `query` or `headers` member, according to the
`in:` the document declares for that name, as the member name
[generator-naming](../generator-naming/spec.md) derives from the documented name.

#### Scenario: all three locations under renamed parameters
- **WHEN** `summariseTask(@Path id: String, @Query("include-done") includeDone: Bool?, @Header("X-Request-Id") requestID: String?)`, declared at `GET /api/v1/tasks/{id}/summary`, returns a `Task` titled `summary of task-<id> done=<includeDone ?? false> req=<requestID ?? "-">` and is called with `GET /api/v1/tasks/9/summary?include-done=true` and `X-Request-Id: abc123`
- **THEN** the response is `200` with title `summary of task-9 done=true req=abc123`

#### Scenario: absent optionals
- **WHEN** the same operation is called as `GET /api/v1/tasks/9/summary` with no query and no header
- **THEN** the response is `200` with title `summary of task-9 done=false req=-`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `typed` and `typedBare` assertions).

### Requirement: An annotation contradicting the document's location is an error
When a bound parameter's annotation, lower-cased, differs from the `in:` the document declares for
its name, WireOpenAPIGen SHALL write
`error: @Operation '<id>' annotates '<name>' as @<Binding>, but the document puts it in <location>. The document decides where a parameter lives; the annotation only says which one this is.`
and exit with status 1.

#### Scenario: `@Query` on a path parameter
- **WHEN** `@Operation func deleteTask(@Query id: String) async throws` implements an operation whose document declares `id` `in: path`
- **THEN** the generator exits 1 with `error: @Operation 'deleteTask' annotates 'id' as @Query, but the document puts it in path. The document decides where a parameter lives; the annotation only says which one this is.`

Pinned by: nothing yet.

### Requirement: A bound name the document does not declare is an error listing the declared ones
When no document parameter of the operation has a bound parameter's documented name,
WireOpenAPIGen SHALL write
`error: @Operation '<id>' binds '<name>', which the document does not declare. It declares <list>. Name the documented parameter — @<Binding>("the-name") — if the Swift name differs.`
and exit with status 1, where `<list>` is the declared parameters as `'<name>' (<location>)`,
sorted and comma-separated, or `no parameters` when there are none.

#### Scenario: the Swift name in place of the documented one
- **WHEN** `summariseTask` binds `@Query includeDone: Bool?` and the document declares `id` in path, `include-done` in query and `X-Request-Id` in header
- **THEN** the generator exits 1 with `error: @Operation 'summariseTask' binds 'includeDone', which the document does not declare. It declares 'X-Request-Id' (header), 'id' (path), 'include-done' (query). Name the documented parameter — @Query("the-name") — if the Swift name differs.`

Pinned by: nothing yet.

### Requirement: An operation binds at most one `@JSONBody`
When an `@Operation` method carries more than one `@JSONBody` parameter, WireOpenAPIGen SHALL write
`error: '<id>' binds <n> request bodies. An operation has one.` and exit with status 1.

#### Scenario: two bodies
- **WHEN** `createTask` declares `@JSONBody a: Components.Schemas.Task, @JSONBody b: Components.Schemas.Task`
- **THEN** the generator exits 1 with `error: 'createTask' binds 2 request bodies. An operation has one.`

Pinned by: nothing yet.

### Requirement: `@JSONBody` is present exactly when the document declares a `requestBody`
An `@Operation` whose document entry declares a `requestBody` SHALL bind it with `@JSONBody`, and one
whose entry declares none SHALL NOT. The first mismatch SHALL be refused with
`error: '<id>' documents a request body, but its handler binds none. Take it with @JSONBody, or use @RawOperation.`
and the second with
`error: '<id>' binds a @JSONBody, but the document declares no request body for it.`, each exiting
with status 1.

#### Scenario: a required body decoded into the handler
- **WHEN** `createTask(@Query("title") title: String, @JSONBody draft: Components.Schemas.Task)`, declared at `POST /api/v1/tasks/new` with a required JSON `requestBody` and `201` as its only success, returns `Task(id: draft.id, title: title)` and is called with `POST /api/v1/tasks/new?title=hello` and body `{"id":"from-body","title":"x"}`
- **THEN** the response is `201` with `"id":"from-body"` and `"title":"hello"`

#### Scenario: a body the handler forgot
- **WHEN** `createTask` is declared with only `@Query("title") title: String`
- **THEN** the generator exits 1 with `error: 'createTask' documents a request body, but its handler binds none. Take it with @JSONBody, or use @RawOperation.`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `created` assertion). The diagnostics are pinned by nothing yet.

### Requirement: `@JSONBody` requires exactly `application/json`
When the documented `requestBody` declares any content types other than exactly
`["application/json"]`, WireOpenAPIGen SHALL write
`error: '<id>' documents a request body of <types>, which @JSONBody cannot decode — it reads JSON only. Use @RawOperation for this operation.`
where `<types>` is the declared list or `no content type`, and exit with status 1.

#### Scenario: a form-encoded body
- **WHEN** the document declares `createTask`'s request body as `application/x-www-form-urlencoded` and the handler binds `@JSONBody`
- **THEN** the generator exits 1 with `error: 'createTask' documents a request body of application/x-www-form-urlencoded, which @JSONBody cannot decode — it reads JSON only. Use @RawOperation for this operation.`

Pinned by: nothing yet.

### Requirement: The body parameter's optionality matches the document's `required:`
A `@JSONBody` parameter's type SHALL end in `?` exactly when the document's `requestBody` is not
`required: true`. A required body bound optionally SHALL be refused with
`error: '<id>' documents a required request body, but its handler takes <Type>. Drop the optionality.`,
and an optional body bound non-optionally with
`error: '<id>' documents an optional request body, but its handler takes <Type>. Make it optional — the document does not promise one will arrive.`
The forwarder SHALL pass the handler the JSON body's value, or `nil` when an optional body is absent.

#### Scenario: an optional body present
- **WHEN** `replaceTask(@Path id: String, @Query("title") title: String, @JSONBody draft: Components.Schemas.Task?)`, declared at `POST /api/v1/tasks/{id}/replace` with an optional `requestBody` and carrying `@JSONResponse(status: .created)`, returns a `Task` titled `<title> from <draft?.id ?? "nothing">` and is called with body `{"id":"B9","title":"x"}` and `title=renamed`
- **THEN** the response is `201` with title `renamed from B9`

#### Scenario: an optional body absent
- **WHEN** the same operation is called with no body
- **THEN** the response is `201` with title `renamed from nothing`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `replaced` and `replacedBare` assertions). The diagnostics are pinned by nothing yet.

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

### Requirement: The status annotation matches whether the handler returns a body
`@JSONResponse(status:)` on a handler with no return type SHALL be refused with
`error: '<id>' returns nothing but names its status with @JSONResponse, which is for a handler that returns a body. Use @ResponseStatus(.<name>).`,
and `@ResponseStatus(_:)` on a handler with a return type with
`error: '<id>' returns a body but names its status with @ResponseStatus, which is for a handler that returns nothing. Use @JSONResponse(status: .<name>).`
A handler with no return type SHALL be answered with `.<case>(.init())`.

#### Scenario: a no-content response chosen by `@ResponseStatus`
- **WHEN** `@Operation @ResponseStatus(.noContent) func deleteTask(@Path id: String) async throws`, whose body logs `deleted: <id>`, implements an operation declared at `POST /api/v1/tasks/{id}/delete` documenting `202` and `204` with no content, and `POST /api/v1/tasks/7/delete` is sent
- **THEN** the response is `204` with an empty body, and the log carries `deleted: 7`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `deleted` assertion and the `deleted: 7` log check). The diagnostics are pinned by nothing yet.

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

### Requirement: Generated names follow the document's naming strategy
WireOpenAPIGen SHALL spell every generated symbol it names (the conformer's requirement, the
`Operations.<X>` namespace of a typed operation, and each `Input` member) as
[generator-naming](../generator-naming/spec.md) derives it under the `namingStrategy` read from the `openapi-generator-config.yaml` passed
for that document, and SHALL use `GeneratorNamingStrategy.generatorDefault`, which is `.defensive`,
when no config is passed, the key is absent, or its value is not a known strategy.

#### Scenario: the idiomatic strategy
- **WHEN** the document's config declares `namingStrategy: idiomatic` and `summariseTask` binds `@Header("X-Request-Id") requestID: String?`
- **THEN** the forwarder reads the `Input`'s `headers.xRequestId`, and a request carrying `X-Request-Id: abc123` reaches the handler with `requestID` equal to `abc123`

#### Scenario: no strategy declared
- **WHEN** the config omits `namingStrategy`
- **THEN** the strategy is `.defensive`

Pinned by: `Tests/WireOpenAPINamingTests/GeneratorSafeNamesTests.swift` (`generatorDefaultIsDefensive`, which pins that `GeneratorNamingStrategy.generatorDefault` is `.defensive`, and `reproducesTheGenerator`), `.github/workflows/build.yml` (`Fixtures` job, the `typed` assertion, and step `Check the naming golden table against the real generator`). The fallback to `generatorDefault` from a missing config, a missing `namingStrategy` key or an unknown value is pinned by nothing yet.

### Requirement: A `@RequestBinding` attribute marks a graph-aware binding
An `@Operation` parameter SHALL be a graph-aware binding when it carries an attribute naming a type
declared anywhere in the scanned sources with `@RequestBinding(Worker.self, …)`; `Worker` is that
binding's **worker**. Its **action** SHALL be the attribute's first argument when that is a string
literal, and the parameter's own name otherwise. Graph-aware bindings are wire-mvc's
[graph-aware-bindings](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/graph-aware-bindings/spec.md);
this specification states only how an `@Operation` forwarder uses one.

#### Scenario: a binding declared in another file
- **WHEN** `TaskController.authorizedTask` declares `@AuthorizedTask("read") task: Components.Schemas.Task`, and `AuthorizedTaskBinding.swift` declares `AuthorizedTask` with `@RequestBinding(TaskAuthorizer.self)`
- **THEN** `task` is a graph-aware binding whose worker is `TaskAuthorizer` and whose action is `read`

Pinned by: `Fixtures/Sources/WireOpenAPIBootstrapExample/Controllers.swift` (`authorizedTask`), `Fixtures/Sources/WireOpenAPIBootstrapExample/AuthorizedTaskBinding.swift` (built by the `Build` step of the `Fixtures` job in `.github/workflows/build.yml`).

### Requirement: A graph-aware binding is not checked against the document
A graph-aware binding SHALL be excused from every check of a bound parameter against the document's
`parameters:` (its name, its location, and its being declared at all), since what it binds is
resolved from the request scope and never crosses the wire. `Input` has no member for it. It SHALL be
checked instead against its worker's scope (see "A graph-aware worker must be `@Scoped` on the owning
controller's seed").

#### Scenario: an action the document does not declare
- **WHEN** `authorizedTask(@Path id: String, @AuthorizedTask("read") task: Components.Schemas.Task)` implements an operation whose document declares only `id` in path
- **THEN** no diagnostic names `read` or `task`, and the target builds

Pinned by: `Fixtures/Sources/WireOpenAPIBootstrapExample/Controllers.swift` (`authorizedTask`, built by the `Build` step of the `Fixtures` job in `.github/workflows/build.yml`).

### Requirement: The forwarder binds a graph-aware parameter through its worker before the handler
For each graph-aware binding, the `@Operation` forwarder SHALL call
`try await <worker>.bind(name: "<action>", request:, pathParameters:, body: nil)` and pass its
result as that argument. The call SHALL come before the handler call and inside the `do` whose
`catch` clauses `@ErrorResponse` emits, so an error the worker throws is mapped as one the handler
throws would be. `body:` SHALL always be `nil`: a graph-aware binding never sees the request body.

#### Scenario: a worker beside a documented parameter
- **WHEN** `TaskController` declares `@Operation @ErrorResponse(TaskForbidden.self, .forbidden) func authorizedTask(@Path id: String, @AuthorizedTask("read") task: Components.Schemas.Task)` and `AuthorizedTask` carries `@RequestBinding(TaskAuthorizer.self)`
- **THEN** the forwarder binds `task` through `TaskAuthorizer` with `bind(name: "read", …, body: nil)` inside the `do` that maps `TaskForbidden` to `.forbidden`, then calls `authorizedTask` with `id` from `Input` and `task` from the worker, and the target builds

Pinned by: `Fixtures/Sources/WireOpenAPIBootstrapExample/Controllers.swift` (`authorizedTask`), `Fixtures/Sources/WireOpenAPIBootstrapExample/AuthorizedTaskBinding.swift` (built by the `Build` step of the `Fixtures` job in `.github/workflows/build.yml`). No probe calls `authorizedTask` at runtime, so the binding's result and the error mapping are pinned by nothing yet.

### Requirement: The conformer carries each worker and fills it per request
When any operation in the group has a graph-aware binding, the conformer SHALL carry, as optionals,
one field for each distinct worker those bindings name, plus the request and its matched path
parameters, which `bind` takes and `Input` does not carry. The template conformer SHALL leave them
all `nil`. A per-request conformer SHALL fill the request and path parameters, and SHALL fill only
the workers the owning controller's own operations name, each from the field swift-wire names for
that worker on the controller's scope entry. Workers named only by a sibling controller's operations
SHALL stay `nil`, because the entry being entered does not yield them. swift-wire names that field
by lower-camel-casing the worker's type name, with `<` spelt `Of` and `,` spelt `And`, the letter
after either upper-cased, and every other character except letters, digits and `_` dropped.

#### Scenario: the worker's scope entry field
- **WHEN** `TaskController`'s `authorizedTask` binds through `TaskAuthorizer`
- **THEN** the per-request conformer built for `TaskController` takes the worker from its scope entry's `taskAuthorizer`

Pinned by: `Fixtures/Sources/WireOpenAPIBootstrapExample/Controllers.swift` (`authorizedTask`, built by the `Build` step of the `Fixtures` job in `.github/workflows/build.yml`). The field-name spelling for a generic worker, and leaving a sibling controller's workers `nil`, are pinned by nothing yet.

### Requirement: A graph-aware worker must be `@Scoped` on the owning controller's seed
For a scope-resolved parameter, WireOpenAPIGen SHALL refuse a worker with no `@Scoped(seed:)` in the
scanned sources with
`error: @Operation '<id>' binds '<name>' through '<Worker>', which is not a @Scoped(seed:) binding. A binding resolved from the request scope has to be one — that is what puts it in the scope its controller enters.`;
a controller with no seed with
`error: @Operation '<id>' binds '<name>' through '<Worker>', which is bound in @Scoped(seed: <S>.self) — but '<Controller>' is not scoped, so it is held directly and enters no scope, and there is nothing to construct '<Worker>' in. Mark '<Controller>' @Scoped(seed: <S>.self).`;
and a controller on a different seed with
`error: @Operation '<id>' binds '<name>' through '<Worker>', which is bound in @Scoped(seed: <S>.self), but '<Controller>' is in @Scoped(seed: <C>.self) — sibling seeded scopes are isolated by design, so its scope entry constructs only its own.`
Each SHALL exit with status 1.

#### Scenario: the worker on an app-scoped controller
- **WHEN** `authorizedTask(@Path id: String, @AuthorizedTask("read") task: Components.Schemas.Task)` is declared on a `@Singleton @OpenAPIController() struct PlainController` carrying no `@ErrorResponse`, where `AuthorizedTask` carries `@RequestBinding(TaskAuthorizer.self)` and `TaskAuthorizer` is `@Scoped(seed: HTTPRequest.self)`
- **THEN** the generator exits 1 with `error: @Operation 'authorizedTask' binds 'task' through 'TaskAuthorizer', which is bound in @Scoped(seed: HTTPRequest.self) — but 'PlainController' is not scoped, so it is held directly and enters no scope, and there is nothing to construct 'TaskAuthorizer' in. Mark 'PlainController' @Scoped(seed: HTTPRequest.self).`

Pinned by: nothing yet.

### Requirement: Every declared operation must be implemented
After its other checks, WireOpenAPIGen SHALL collect the operationIds the document declares that
no marked method in the group implements, sorted, and when any remain SHALL write
`error: every operation the document declares must be implemented, and <ids> <is|are> not. Mark the <method that implements it|methods that implement them> with @Operation or @RawOperation.`
and exit with status 1.

#### Scenario: one operation left out
- **WHEN** the document declares `gatedTask` and no marked method in the group implements it, while every other operation it declares is implemented
- **THEN** the generator exits 1 with `error: every operation the document declares must be implemented, and gatedTask is not. Mark the method that implements it with @Operation or @RawOperation.`

Pinned by: nothing yet.

### Requirement: A marked method naming an undeclared operation is an error
When a marked method's operationId is not declared by the document, WireOpenAPIGen SHALL write
`error: '<method>' is marked as operation '<id>', which the document does not declare. It declares '<a>', '<b>'.`
over the sorted operationIds, and exit with status 1. A document declaring no operations never
reaches this check: WireOpenAPIGen refuses it first with
`error: @OpenAPIController needs the OpenAPI document to derive its routes, and none was passed (--spec).`,
which is tracked as a defect in https://github.com/swift-wire/wire-open-api/issues/88.

#### Scenario: a misspelt method
- **WHEN** a controller declares `@RawOperation func getTasks(_ input: Operations.GetTasks.Input) async throws -> Operations.GetTasks.Output` against a document whose operationIds are `getTask`, `authorizedTask`, `gatedTask`, `listTasks`, `summariseTask`, `createTask`, `deleteTask` and `replaceTask`
- **THEN** the generator exits 1 with `error: 'getTasks' is marked as operation 'getTasks', which the document does not declare. It declares 'authorizedTask', 'createTask', 'deleteTask', 'gatedTask', 'getTask', 'listTasks', 'replaceTask', 'summariseTask'.`

Pinned by: nothing yet.

### Requirement: One operation has one owner
When two marked methods in a group name the same operationId, WireOpenAPIGen SHALL write
`error: <A> and <B> both declare @RawOperation '<id>'. One operation is mounted once, so exactly one controller may implement it.`
for the first clashing operationId in sorted order, with the owning type names sorted, and exit with
status 1. The message SHALL say `@RawOperation` whichever marker was used.

#### Scenario: two controllers on one operation
- **WHEN** `TaskController` and `TaskListController` both declare `@RawOperation func getTask(…)`
- **THEN** the generator exits 1 with `error: TaskController and TaskListController both declare @RawOperation 'getTask'. One operation is mounted once, so exactly one controller may implement it.`

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

## Related specifications

- [controller-collation](../controller-collation/spec.md)
- [route-mounting](../route-mounting/spec.md)
- [error-mapping-and-scope](../error-mapping-and-scope/spec.md)
- [schema-validation](../schema-validation/spec.md)
- [document-reading](../document-reading/spec.md)
- [generator-naming](../generator-naming/spec.md)
- [build-plugins-and-gen-cli](../build-plugins-and-gen-cli/spec.md)
- [wire-mvc request-bindings](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/request-bindings/spec.md)
- [wire-mvc graph-aware-bindings](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/graph-aware-bindings/spec.md)
- [wire-mvc responses-and-modes](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/responses-and-modes/spec.md)
