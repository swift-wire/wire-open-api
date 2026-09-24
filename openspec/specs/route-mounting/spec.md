# Route mounting

## Purpose

How WireOpenAPIGen mounts a document's operations as wire-mvc routes. For each group it fills the
body of the swift-wire aggregate proxy with a `RouteContributor` conformance that builds one
`UniversalServer` per document, registers every operation individually at its prefixed path on the
builder it is given, folds the owning controller's and the operation's `@Middleware` around it, and
dispatches through `WireOpenAPIRoutes.invoke`. A request-scoped controller enters its own scope per
request and is reached by re-pointing a copy of the server at a per-request conformer. The builder
contract and the middleware fold are wire-mvc's, linked below rather than restated.

Rationale: [WireOpenAPIAdvanced](../../../Documentation/Notes/WireOpenAPIAdvanced.md).
Documentation: [ServingTheRoutes](../../../Sources/WireOpenAPI/WireOpenAPI.docc/ServingTheRoutes.md), [SeveralSpecsInOneApp](../../../Sources/WireOpenAPI/WireOpenAPI.docc/SeveralSpecsInOneApp.md), [SharingASpec](../../../Sources/WireOpenAPI/WireOpenAPI.docc/SharingASpec.md).

## Requirements

### Requirement: Each group's proxy gains a `RouteContributor` witness
For each group WireOpenAPIGen SHALL emit `extension _WireOpenAPIContributor_<Group>: RouteContributor`
declaring `func registerWireRoutes<Builder: HTTPServerRouteBuilder>(on builder: inout Builder, coding wireMVCAppCoding: WireMVCCoding) throws`
constrained by `Builder.RequestContext: ~Copyable & SendableMetatype & ResponseHeaderCarrying`,
`Builder.Reader: ~Copyable`, `Builder.ResponseSender: ~Copyable` and
`Builder.ResponseSender.Writer: ~Copyable`. Groups SHALL be emitted in ascending order of group name,
each preceded by its conformer namespace.

#### Scenario: two documents in one app
- **WHEN** the fixture app holds the `OrdersAPI` group and the `WireOpenAPIBootstrapExample` group
- **THEN** `_WireOpenAPIHandlers.swift` declares `enum _WireOpenAPISpec_OrdersAPI` and `extension _WireOpenAPIContributor_OrdersAPI: RouteContributor` before `enum _WireOpenAPISpec_WireOpenAPIBootstrapExample` and `extension _WireOpenAPIContributor_WireOpenAPIBootstrapExample: RouteContributor`, and both documents' operations serve

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, `Build` step, and the `openapi` and `order` assertions of step `Serve an OpenAPI operation and a @Get route from one router`).

### Requirement: The emitted file imports the runtime under its SPI
The emitted file SHALL import the sorted, de-duplicated set of `Foundation`, `OpenAPIRuntime`,
`WireMVC`, `WireOpenAPI`, every `--import` module, and `Wire` when some request-scoped controller is
generic. `OpenAPIRuntime` and every module passed with `--spec-module` SHALL be imported as
`@_spi(Generated) import`, and every other module as a plain `import`.

#### Scenario: a dependency carrying a document
- **WHEN** the plugin passes `--spec-module OrdersAPI …` and `--import OrdersAPI`
- **THEN** the file contains `@_spi(Generated) import OpenAPIRuntime` and `@_spi(Generated) import OrdersAPI`, and `import WireMVC`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, `Build` step).

### Requirement: One `UniversalServer` template is built per document at registration
`registerWireRoutes` SHALL construct `let wireOpenAPIServerTemplate = UniversalServer(handler:configuration:)`
once, before any registration, passing the template conformer as `handler` and
`Configuration(wireMVCCoding: wireMVCAppCoding)` as `configuration`, so the app's coding reaches
every operation of the document. The template conformer SHALL hold each app-scoped controller from
the proxy's subject field and `nil` for each request-scoped one.

#### Scenario: the app's coding reaches an operation
- **WHEN** the fixture's composition root declares `WireMVCCoding(json: .init(sortsKeys: true))` and a client requests `GET /api/v1/tasks/42`
- **THEN** the body begins `{"at":` and lists `"id":"42"` before `"title":`, and `"at"` is `"2023-11-14T22:13:20Z"`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `the app-wide sortsKeys did not reach the OpenAPI operation` and ISO8601 checks).

### Requirement: A document with servers passes `Servers.Server1` as the server URL
When the document declares servers whose URL paths are all equal, the template SHALL be built with
`serverURL: try <Servers>.Server1.url()` ahead of `handler:`, where `<Servers>` is `Servers` for the
compiling target's own document and `<M>.Servers` for a document in module `M`.

#### Scenario: a document in a dependency module
- **WHEN** `OrdersAPI`'s document declares `servers: [{url: /api/v2}]`
- **THEN** the template is built with `serverURL: try OrdersAPI.Servers.Server1.url()`, and `GET /api/v2/orders/7` answers `200` with `"item":"item-7 via /api/v2/orders/7"`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `order` assertion).

### Requirement: A document with no servers registers without a prefix
When the document declares no servers, or no document was loaded, the template SHALL be built with
no `serverURL:` argument.

#### Scenario: no `servers:` block
- **WHEN** a document declares `paths: /tasks/{id}` and no `servers:`
- **THEN** the emitted `UniversalServer(` call has no `serverURL:` argument and the operation registers at `/tasks/{id}`

Pinned by: nothing yet.

### Requirement: Servers with differing paths are a build error
When the document's servers resolve to more than one distinct URL path, WireOpenAPIGen SHALL write
`<document>: error: the document declares servers with different paths (<paths>). Operations register under one prefix, so there is no single answer — give the servers a common path, or split the document.`
with the paths sorted and comma-separated, and exit with status 1.

#### Scenario: two versions in one document
- **WHEN** a document declares `servers: [{url: /api/v1}, {url: /api/v2}]`
- **THEN** the generator exits 1 with `error: the document declares servers with different paths (/api/v1, /api/v2). Operations register under one prefix, so there is no single answer — give the servers a common path, or split the document.`

Pinned by: nothing yet.

### Requirement: Every implemented operation is registered at its prefixed path, in operationId order
For each operationId the document declares and a controller in the group implements, in ascending
operationId order, the witness SHALL open a `do` block, compute
`let wireOpenAPIPath = try wireOpenAPIServerTemplate.apiPathComponentsWithServerPrefix("<paths key>")`,
and call `builder.register(method: .<method>, path: wireOpenAPIPath)` with the document's HTTP method
lower-cased.

#### Scenario: the prefixed path serves and the bare one does not
- **WHEN** the Tasks document declares `servers: [{url: /api/v1}]` and `paths: /tasks/{id}` for `getTask`
- **THEN** `GET /api/v1/tasks/42` answers `200` and `GET /tasks/42` answers `404`

#### Scenario: each document keeps its own prefix
- **WHEN** the Orders document is under `/api/v2` and the Tasks document under `/api/v1`
- **THEN** `GET /api/v1/orders/7` answers `404` and `GET /api/v2/tasks` answers `404`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `openapi`, `unprefixed`, `crossed` and `crossed2` assertions).

### Requirement: Operations register on the same builder as annotation-driven routes
The witness SHALL register on the builder `WireMVC.apply` passes it, so an operation is served by the
same router, `@NotFound` fallback and global `@Middleware` as a wire-mvc `@Get` route.

#### Scenario: one router
- **WHEN** the fixture serves `GET /api/v1/tasks/42`, `GET /status/tasks` and `GET /nope`
- **THEN** the first two answer `200`, and `/nope` answers `404` with the `@NotFound` body `no route here`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `openapi`, `mvc` and `notfound` assertions).

### Requirement: The fold is the owning controller's `@Middleware`, then the operation's
When the owning controller or the operation declares `@Middleware`, the registration SHALL build a
`RequestResponseMiddlewareBox.pending` over the courier's `base`, carrying
`RouteContext(template: wireOpenAPIPath, pathParameters: parameters)` and the courier's response
headers, and run it through `wireCompose { … }` whose entries are the declaring controller's
`@Middleware` arguments in source order followed by the method's. An argument `T.self` SHALL read
`self._wire<T>` by `dependencyPropertyName(forType:)`, and any other argument SHALL read
`self._wireFactory_<key>.create(Builder.RequestContext.Base.self, Builder.Reader.self, Builder.ResponseSender.self)`
with `<key>` sanitised by `sanitizedKeyFragment`. A registration with no entries SHALL build no box.

#### Scenario: controller scope and route scope
- **WHEN** `TaskController` carries `@Middleware(RequireAPIKeyKeys.factory)` and `listTasks` on `TaskListController` carries `@Middleware(AuditKeys.factory)`
- **THEN** the log shows `apikey: GET /api/v1/tasks/42` and `audit: /api/v1/tasks`, and no `audit: /api/v1/tasks/42`

#### Scenario: one component on both kinds of route
- **WHEN** `StatusController` carries the same `@Middleware(RequireAPIKeyKeys.factory)` on a `@Get`
- **THEN** the log shows `apikey: GET /status/tasks` as well

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `middleware log` checks).

### Requirement: Controller-scope middleware stays with the controller that declared it
The fold for an operation SHALL include controller-scope entries only from the controller that
implements that operation, not from other controllers in the group or in another group.

#### Scenario: a sibling controller without middleware
- **WHEN** `TaskController` declares `@Middleware(RequireAPIKeyKeys.factory)` and `TaskListController`, on the same document, declares none
- **THEN** no `apikey: GET /api/v1/tasks` line is logged, and no `apikey: GET /api/v2/orders/7` line is logged

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `controller-scope @Middleware leaked between controllers sharing a spec` and `@Middleware leaked from one spec to another` checks).

### Requirement: The response goes out through the courier's header registry
Each registration SHALL take the courier's contents with `requestContext.takeContents()` and its
registry with `responseHeaders.take()` (through `withPendingContents` when there is a fold), and every
send SHALL be through `ResponseHeaderApplyingSender(wrapping: sender, registry: wireOpenAPIRegistry)`,
so header contributions from middleware reach an operation's response.

#### Scenario: a global middleware's header
- **WHEN** a global `@Middleware` adds `x-served-by: wire-open-api`
- **THEN** `GET /api/v1/tasks/42`, `GET /status/tasks` and the `401` refusal of `GET /api/v1/tasks/42/gated` all carry `x-served-by: wire-open-api`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `openapiServedBy`, `mvcServedBy` and `gatedServedBy` checks).

### Requirement: The terminal dispatches through `WireOpenAPIRoutes.invoke`
The route terminal SHALL call `WireOpenAPIRoutes.invoke(handler:request:pathParameters:reader:sender:rejectionResponse:operationID:)`
with a `@Sendable` handler that calls `wireOpenAPIServer.<method>(request:body:metadata:)`, where
`<method>` is the implementing controller method's own name, and with `operationID:` the operation's
id. `invoke` SHALL collect the request body, pass it as `nil` when empty, and send the generated
`HTTPResponse` and body through the sender it was given.

#### Scenario: a request-scoped operation
- **WHEN** `GET /api/v1/tasks/42` is served
- **THEN** the terminal calls `wireOpenAPIServer.getTask(request:body:metadata:)` inside `WireOpenAPIRoutes.invoke`, and the response is `200`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `openapi` assertion).

### Requirement: Bodies are collected up to 1,000,000 bytes
`WireOpenAPIRoutes.invoke` and `WireOpenAPIRoutes.refuse` SHALL default `maximumBodySize` to
`1_000_000`, and the generated terminal SHALL pass no other value. `invoke` SHALL collect the request
body with `WireMVCRequest.collectBody(_:maximumSize:)` and the response body with
`[UInt8](collecting:upTo:)` under that limit.

#### Scenario: the generated call
- **WHEN** WireOpenAPIGen emits any terminal
- **THEN** its `WireOpenAPIRoutes.invoke(` call carries no `maximumBodySize:` argument

Pinned by: nothing yet.

### Requirement: An app-scoped controller's operation uses the template as is
When the implementing controller has no `@Scoped(seed:)`, the terminal SHALL bind
`let wireOpenAPIServer = wireOpenAPIServerTemplate` and enter no scope, even when another controller
in the group is request-scoped.

#### Scenario: an app-scoped operation beside a scoped one
- **WHEN** `GET /api/v1/tasks` is served by `TaskListController` and `GET /api/v2/orders` by `OrderSummaryController`
- **THEN** no `scope: constructed for /api/v1/tasks` and no `scope: order trace for /api/v2/orders` line is logged

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, both `an app-scoped controller's operation entered a request scope` checks).

### Requirement: A scoped controller enters only its own scope and re-points a copy of the template
When the implementing controller has `@Scoped(seed:)`, the terminal SHALL call
`self._wireEnterScope[_<Controller>](request)`, bind `wireOpenAPIEntry._wireSubject` and
`wireOpenAPIEntry._wireScopeTeardown`, copy the template into `var wireOpenAPIRebound`, set its
`handler` to a conformer holding that subject in the controller's field, the app-scoped subjects from
the proxy and `nil` for every other request-scoped field, and dispatch through the copy. It SHALL
NOT construct a new `UniversalServer` per request.

#### Scenario: the subject follows the request
- **WHEN** `GET /api/v1/tasks/42` and then `GET /api/v1/tasks/99` are served by the request-scoped `TaskController`
- **THEN** the responses carry `task-42 via /api/v1/tasks/42` and `task-99 via /api/v1/tasks/99`, and the log shows `scope: constructed for` each path

#### Scenario: the second document's scope
- **WHEN** `GET /api/v2/orders/7` and `/api/v2/orders/9` are served by the request-scoped `OrderController`
- **THEN** each response carries its own id and path, and the log shows `scope: order trace for /api/v2/orders/7`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `other`, `order` and `order2` assertions and the `scope log` checks).

### Requirement: Scope teardown runs after the response and on a throw
A scoped terminal SHALL wrap the `invoke` call in `do`/`catch`, call `_ = await wireOpenAPITeardown()`
and rethrow when it throws, and call `_ = await wireOpenAPITeardown()` after it returns.

#### Scenario: a handler that throws
- **WHEN** a request-scoped operation's `invoke` throws an error no tier answers
- **THEN** the scope's teardown runs before the error propagates to the router

Pinned by: nothing yet.

### Requirement: The conformer lives in a per-document namespace
Each group's `Conformer` SHALL be declared inside `enum _WireOpenAPISpec_<Group>`, with `<Group>`
sanitised by `sanitizedKeyFragment`, or `enum _WireOpenAPISpec` for an empty group name. When the
document belongs to another module `M`, the namespace SHALL first declare
`typealias APIProtocol = M.APIProtocol`, `typealias Components = M.Components`,
`typealias Operations = M.Operations` and `typealias Servers = M.Servers`; for the compiling
target's own document it SHALL declare none.

#### Scenario: two documents spelling their types identically
- **WHEN** the app generates the Tasks document and imports `OrdersAPI`, and `OrderController` writes `Operations.GetOrder.Input` unqualified in its own module
- **THEN** the emitted `enum _WireOpenAPISpec_OrdersAPI` carries the four typealiases, `enum _WireOpenAPISpec_WireOpenAPIBootstrapExample` carries none, and both `GET /api/v2/orders/7` and `GET /api/v1/tasks/42` answer `200`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, `Build` step, and the `order` and `openapi` assertions of step `Serve an OpenAPI operation and a @Get route from one router`).

## Related specifications

- [controller-collation](../controller-collation/spec.md)
- [operation-forms](../operation-forms/spec.md)
- [error-mapping-and-scope](../error-mapping-and-scope/spec.md)
- [coding-bridge](../coding-bridge/spec.md)
- [schema-validation](../schema-validation/spec.md)
- [document-reading](../document-reading/spec.md)
- [build-plugins-and-gen-cli](../build-plugins-and-gen-cli/spec.md)
- [wire-mvc route-builder-contract](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/route-builder-contract/spec.md)
- [wire-mvc middleware](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/middleware/spec.md)
- [wire-mvc response-headers](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/response-headers/spec.md)
- [wire-mvc request-scope](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/request-scope/spec.md)
