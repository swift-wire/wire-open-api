# Operation forms

## Purpose

The two ways a controller method implements an OpenAPI operation, and what WireOpenAPIGen checks
about each against the document. `@RawOperation` hands the method the generated `Input` and takes
back its `Output`; `@Operation` binds each parameter from the `Input` member the document places it
in, or from the request scope for a graph-aware binding, and wraps the return value in the response
the document declares. Both are forwarded to from one generated `Conformer`, and every operation the
document declares must be implemented by exactly one marked method.

Rationale: [WireOpenAPIAdvanced](../../../Documentation/Notes/WireOpenAPIAdvanced.md).
Documentation: [Operations](../../../Sources/WireOpenAPI/WireOpenAPI.docc/Operations.md), [WritingAnOpenAPIController](../../../Sources/WireOpenAPI/WireOpenAPI.docc/WritingAnOpenAPIController.md).

## Requirements

### Requirement: The operation markers expand to nothing
`@RawOperation()`, `@RawOperation(_ operationID: String)`, `@Operation()` and
`@Operation(_ operationID: String)` SHALL be attached peer macros implemented by
`OpenAPIControllerMacro`, whose expansion returns no peers. What a marked method means SHALL be
decided by WireOpenAPIGen reading the source, not by the macro.

#### Scenario: a marked method compiles unchanged
- **WHEN** `TaskListController` declares `@RawOperation func listTasks(_ input: Operations.ListTasks.Input) async throws -> Operations.ListTasks.Output`
- **THEN** the fixture builds with the method as written, and `GET /api/v1/tasks` answers `200` with `["1","2","3"]`

Pinned by: `Sources/WireOpenAPI/OpenAPIController.swift` (the macro declarations), `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `list` assertion). The empty expansion of the operation markers is pinned by nothing yet.

### Requirement: The bare marker takes the method name as the operationId
`ControllerScanner` SHALL take a method's operationId from the string literal passed to
`@RawOperation(_:)` or `@Operation(_:)` when one is given, and from the method's own name otherwise.
The conformer SHALL implement the `APIProtocol` requirement named
`GeneratorSafeNames.swiftMemberName(for: operationID, strategy:)` and forward it to the method by
the method's own name.

#### Scenario: the bare form
- **WHEN** `TaskController` declares a bare `@RawOperation func getTask(_ input: Operations.GetTask.Input)`
- **THEN** it implements operationId `getTask`, and `GET /api/v1/tasks/42` answers `200` with a title of `task-42 via /api/v1/tasks/42`

#### Scenario: the declared form
- **WHEN** a controller declares `@RawOperation("get-task") func fetch(_ input: Operations.GetTask.Input) async throws -> Operations.GetTask.Output` under the `defensive` strategy
- **THEN** the conformer declares the requirement `GeneratorSafeNames.swiftMemberName(for: "get-task", strategy: .defensive)` and its body calls `fetch(input)`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `openapi` assertion). The declared form is pinned by nothing yet.

### Requirement: `@RawOperation` takes one `Input` and returns its `Output`
A `@RawOperation` method SHALL declare exactly one parameter and a return type, and its forwarder
SHALL pass the generated `Input` through unchanged and return what the method returns. The
forwarder's signature SHALL copy the method's parameter and return types exactly as written.
Otherwise WireOpenAPIGen SHALL write
`<file>:<line>: error: @RawOperation '<id>' must take the operation's generated Input and return its Output — that is the shape the generated operation method dispatches to.`
at the method name's line and exit with status 1.

#### Scenario: types written qualified
- **WHEN** `OrderSummaryController` declares `@RawOperation func listOrders(_ input: OrdersAPI.Operations.ListOrders.Input) async throws -> OrdersAPI.Operations.ListOrders.Output`
- **THEN** the forwarder is declared with those spellings, and `GET /api/v2/orders` answers `200` with a body containing `"item-7"` and `"item-9"`

#### Scenario: a raw method with no return
- **WHEN** a controller declares `@RawOperation func getTask(_ input: Operations.GetTask.Input) async throws`
- **THEN** the generator exits 1 with `error: @RawOperation 'getTask' must take the operation's generated Input and return its Output — that is the shape the generated operation method dispatches to.`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `summary` assertion). The diagnostic is pinned by nothing yet.

### Requirement: Every `@Operation` parameter carries a binding annotation
Each parameter of an `@Operation` method SHALL carry `@Path`, `@Query`, `@Header`, `@JSONBody`, or
an attribute naming a type declared with `@RequestBinding(Worker.self)`. A parameter carrying none
SHALL be refused with
`<file>:<line>: error: parameter '<name>' of @Operation '<id>' needs a binding annotation — one of @Path, @Query, @Header, @JSONBody. The document says where each parameter lives; the annotation says which one this is.`
at the parameter's line, and the generator SHALL exit with status 1.

#### Scenario: a parameter left bare
- **WHEN** `@Operation func summariseTask(id: String) async throws -> Components.Schemas.Task` is declared
- **THEN** the generator exits 1 with `error: parameter 'id' of @Operation 'summariseTask' needs a binding annotation — one of @Path, @Query, @Header, @JSONBody. The document says where each parameter lives; the annotation says which one this is.`

Pinned by: nothing yet.

### Requirement: The document decides where a bound parameter is read from
For a `@Path`, `@Query` or `@Header` parameter, the documented name SHALL be the attribute's string
literal argument when given and the parameter's own name otherwise. The forwarder SHALL read it as
`input.<location>.<member>`, where `<location>` is `path`, `query` or `headers` according to the
`in:` the document declares for that name, and `<member>` is
`GeneratorSafeNames.swiftMemberName(for: documentedName, strategy:)`.

#### Scenario: all three locations under renamed parameters
- **WHEN** `summariseTask(@Path id: String, @Query("include-done") includeDone: Bool?, @Header("X-Request-Id") requestID: String?)` is called with `GET /api/v1/tasks/9/summary?include-done=true` and `X-Request-Id: abc123`
- **THEN** the response is `200` with title `summary of task-9 done=true req=abc123`

#### Scenario: absent optionals
- **WHEN** the same operation is called as `GET /api/v1/tasks/9/summary` with no query and no header
- **THEN** the response is `200` with title `summary of task-9 done=false req=-`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `typed` and `typedBare` assertions).

### Requirement: An annotation contradicting the document's location is an error
When a bound parameter's annotation, lower-cased, differs from the `in:` the document declares for
its name, `diagnoseTypedBindings` SHALL write
`error: @Operation '<id>' annotates '<name>' as @<Binding>, but the document puts it in <location>. The document decides where a parameter lives; the annotation only says which one this is.`
and exit with status 1.

#### Scenario: `@Query` on a path parameter
- **WHEN** `@Operation func deleteTask(@Query id: String) async throws` implements an operation whose document declares `id` `in: path`
- **THEN** the generator exits 1 with `error: @Operation 'deleteTask' annotates 'id' as @Query, but the document puts it in path. The document decides where a parameter lives; the annotation only says which one this is.`

Pinned by: nothing yet.

### Requirement: A bound name the document does not declare is an error listing the declared ones
When no document parameter of the operation has a bound parameter's documented name,
`diagnoseTypedBindings` SHALL write
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
- **WHEN** `createTask(@Query("title") title: String, @JSONBody draft: Components.Schemas.Task)` is called with `POST /api/v1/tasks/new?title=hello` and body `{"id":"from-body","title":"x"}`
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
The forwarder SHALL unwrap `input.body` with a `switch` whose `.json` case yields the value, adding a
`.none` case yielding `nil` for an optional body.

#### Scenario: an optional body present
- **WHEN** `replaceTask(@Path id: String, @Query("title") title: String, @JSONBody draft: Components.Schemas.Task?)` is called with body `{"id":"B9","title":"x"}` and `title=renamed`
- **THEN** the response is `201` with title `renamed from B9`

#### Scenario: an optional body absent
- **WHEN** the same operation is called with no body
- **THEN** the response is `201` with title `renamed from nothing`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `replaced` and `replacedBare` assertions). The diagnostics are pinned by nothing yet.

### Requirement: A single documented success is inferred, several must be named
An `@Operation` naming no status SHALL construct the operation's one documented `2xx` response, and
SHALL be refused when the document declares zero or several with
`error: '<id>' documents <n> success responses (<cases>), so which one the handler returns cannot be inferred. Name it with @JSONResponse(status:) or @ResponseStatus(_:).`
(`no` in place of `<n>`, and no parenthesised list, when there are none). A status named with
`@JSONResponse(status:)` or `@ResponseStatus(_:)` SHALL be matched against the document's responses
by `GeneratorStatusNames.safeName(for:)`, and one the document does not declare SHALL be refused with
`error: @JSONResponse(status: .<name>) on '<id>' names a status the document does not declare. It declares <code> (.<case>), ….`

#### Scenario: a non-200 success inferred
- **WHEN** `createTask` names no status and its document declares only `201` among its successes
- **THEN** the forwarder returns `.created(.init(body: .json(…)))` and the `created` probe answers `201`

#### Scenario: one of two successes named
- **WHEN** `replaceTask` documents `200` and `201` and carries `@JSONResponse(status: .created)`
- **THEN** the `replaced` probe answers `201`

#### Scenario: two successes and no name
- **WHEN** `replaceTask` loses its `@JSONResponse(status: .created)`
- **THEN** the generator exits 1 with `error: 'replaceTask' documents 2 success responses (.ok, .created), so which one the handler returns cannot be inferred. Name it with @JSONResponse(status:) or @ResponseStatus(_:).`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `created` and `replaced` assertions). The diagnostics are pinned by nothing yet.

### Requirement: The status annotation matches whether the handler returns a body
`@JSONResponse(status:)` on a handler with no return type SHALL be refused with
`error: '<id>' returns nothing but names its status with @JSONResponse, which is for a handler that returns a body. Use @ResponseStatus(.<name>).`,
and `@ResponseStatus(_:)` on a handler with a return type with
`error: '<id>' returns a body but names its status with @ResponseStatus, which is for a handler that returns nothing. Use @JSONResponse(status: .<name>).`
A handler with no return type SHALL be answered with `.<case>(.init())`.

#### Scenario: a no-content response chosen by `@ResponseStatus`
- **WHEN** `@Operation @ResponseStatus(.noContent) func deleteTask(@Path id: String) async throws` implements an operation documenting `202` and `204` with no content, and `POST /api/v1/tasks/7/delete` is sent
- **THEN** the response is `204` with an empty body, and the log carries `deleted: 7`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `deleted` assertion and the `deleted: 7` log check). The diagnostics are pinned by nothing yet.

### Requirement: The selected response must be one the typed shim can construct
Against the selected response, WireOpenAPIGen SHALL refuse a body whose content types are not
exactly `application/json` with
`error: '<id>' responds with <types>, which the typed shim cannot construct yet — it builds JSON bodies only. Use @RawOperation for this operation.`,
a response with a body whose handler returns nothing with
`error: '<id>' documents a <code> response with a body, but its handler returns nothing. Return the response body's type.`,
and a response with no content whose handler returns a value with
`error: '<id>' documents a <code> response with no content, but its handler returns <Type>. Drop the return, or document a body.`
These three are reported at the group's first controller's declaration line.

#### Scenario: a plain-text success
- **WHEN** `@Operation func getReport() async throws -> String` implements `getReport`, whose only success is `200` with `text/plain`
- **THEN** the generator exits 1 with `error: 'getReport' responds with text/plain, which the typed shim cannot construct yet — it builds JSON bodies only. Use @RawOperation for this operation.`

Pinned by: nothing yet.

### Requirement: Generated names follow the document's naming strategy
WireOpenAPIGen SHALL spell every generated symbol it names (the conformer's requirement, the
`Operations.<X>` namespace of a typed operation, and each `Input` member) with
`GeneratorSafeNames` under the `namingStrategy` read from the `openapi-generator-config.yaml` passed
for that document, and SHALL use `GeneratorNamingStrategy.generatorDefault`, which is `.defensive`,
when no config is passed, the key is absent, or its value is not a known strategy.

#### Scenario: the idiomatic strategy
- **WHEN** the fixture's config declares `namingStrategy: idiomatic` and a handler binds `@Header("X-Request-Id")`
- **THEN** the forwarder reads `input.headers.xRequestId`, and the `typed` probe echoes `req=abc123`

#### Scenario: no strategy declared
- **WHEN** the config omits `namingStrategy`
- **THEN** the strategy is `.defensive`

Pinned by: `Tests/WireOpenAPINamingTests/GeneratorSafeNamesTests.swift` (`generatorDefaultIsDefensive`, `reproducesTheGenerator`), `.github/workflows/build.yml` (`Fixtures` job, the `typed` assertion, and step `Check the naming golden table against the real generator`).

### Requirement: A graph-aware binding is resolved by its worker inside the forwarder
A parameter attribute naming a type declared anywhere in the scanned sources with
`@RequestBinding(Worker.self, …)` SHALL be treated as scope-resolved: it SHALL be excused from the
document's parameter checks, the conformer SHALL carry optional fields `_wireWorker_<Worker>`,
`_wireRequest: HTTPRequest?` and `_wirePathParameters: [String: Substring]?`, and the forwarder SHALL
bind it, before calling the handler and inside the `do` the `@ErrorResponse` catches wrap, with
`try await <worker>.bind(name: "<documentedName>", request:, pathParameters:, body: nil)`. A
per-request conformer SHALL fill the worker field from `wireOpenAPIEntry.<field>`, where `<field>` is
`scopeYieldFieldName(forType: Worker)`, only for workers the owning controller's own operations name.

#### Scenario: a worker beside a documented parameter
- **WHEN** `TaskController` declares `@Operation @ErrorResponse(TaskForbidden.self, .forbidden) func authorizedTask(@Path id: String, @AuthorizedTask("read") task: Components.Schemas.Task)` and `AuthorizedTask` carries `@RequestBinding(TaskAuthorizer.self)`
- **THEN** the forwarder calls `bind(name: "read", …)` on `_wireWorker_TaskAuthorizer`, the per-request conformer fills it from `wireOpenAPIEntry.taskAuthorizer`, and the fixture builds

Pinned by: `Fixtures/Sources/WireOpenAPIBootstrapExample/Controllers.swift` (`authorizedTask`), `Fixtures/Sources/WireOpenAPIBootstrapExample/AuthorizedTaskBinding.swift` (built by the `Build` step of the `Fixtures` job in `.github/workflows/build.yml`). No probe calls `authorizedTask` at runtime.

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
- **WHEN** `authorizedTask(@Path id: String, @AuthorizedTask("read") task: Components.Schemas.Task)` is declared on a `@Singleton @OpenAPIController() struct PlainController` carrying no `@ErrorResponse`
- **THEN** the generator exits 1 with `error: @Operation 'authorizedTask' binds 'task' through 'TaskAuthorizer', which is bound in @Scoped(seed: HTTPRequest.self) — but 'PlainController' is not scoped, so it is held directly and enters no scope, and there is nothing to construct 'TaskAuthorizer' in. Mark 'PlainController' @Scoped(seed: HTTPRequest.self).`

Pinned by: nothing yet.

### Requirement: Every declared operation must be implemented
After its other checks, `diagnoseCoverage` SHALL collect the operationIds the document declares that
no marked method in the group implements, sorted, and when any remain SHALL write
`error: every operation the document declares must be implemented, and <ids> <is|are> not. Mark the <method that implements it|methods that implement them> with @Operation or @RawOperation.`
and exit with status 1.

#### Scenario: one operation left out
- **WHEN** `GatedTaskController` is removed from the fixture, leaving `gatedTask` unimplemented
- **THEN** the generator exits 1 with `error: every operation the document declares must be implemented, and gatedTask is not. Mark the method that implements it with @Operation or @RawOperation.`

Pinned by: nothing yet.

### Requirement: A marked method naming an undeclared operation is an error
When a marked method's operationId is not declared by the document, WireOpenAPIGen SHALL write
`error: '<method>' is marked as operation '<id>', which the document does not declare. <declared>`
where `<declared>` is `It declares '<a>', '<b>'.` over the sorted operationIds, or
`The document declares none.`, and exit with status 1.

#### Scenario: a misspelt method
- **WHEN** a controller declares `@RawOperation func getTasks(_ input: Operations.GetTasks.Input) async throws -> Operations.GetTasks.Output` against the fixture's Tasks document
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
scanned file and the line of the method or parameter; one found against the document SHALL name the
line of the operation's method where one is in hand and the controller's line otherwise, with
`<file>` the source file of the group's first controller.

#### Scenario: the fixture compiles clean
- **WHEN** the `Fixtures` package is built with every controller as checked in
- **THEN** WireOpenAPIGen writes no diagnostic and the build succeeds

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, `Build` step), `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (the shared `<file>:<line>: error:` shape, for the error-mapping refusals it holds).

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
