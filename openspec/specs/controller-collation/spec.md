# Controller collation

## Purpose

How a type marked `@OpenAPIController` becomes a member of one generated proxy per OpenAPI document.
The marker macro, the `WireAdapterAnnotationV1` alias that directs swift-wire to synthesise an
aggregate proxy into `WireMVCKeys.routeContributors`, the rule WireOpenAPIGen uses to decide which
document a controller implements, the name of the proxy each group lands on, and the shapes of
controller declaration the generator accepts and refuses. The swift-wire side of the aggregate-proxy
contract and the wire-mvc collation key are specified in their own repositories and linked below.

Rationale: [WireOpenAPIAdvanced](../../../Documentation/Notes/WireOpenAPIAdvanced.md), [WireOpenAPIDesign](../../../Documentation/Notes/WireOpenAPIDesign.md).
Documentation: [WritingAnOpenAPIController](../../../Sources/WireOpenAPI/WireOpenAPI.docc/WritingAnOpenAPIController.md), [SharingASpec](../../../Sources/WireOpenAPI/WireOpenAPI.docc/SharingASpec.md), [SeveralSpecsInOneApp](../../../Sources/WireOpenAPI/WireOpenAPI.docc/SeveralSpecsInOneApp.md).

## Requirements

### Requirement: The `@OpenAPIController` macro expands to nothing
`@OpenAPIController()` and `@OpenAPIController(spec: String)` SHALL be attached peer macros
implemented by `OpenAPIControllerMacro`, whose `expansion` returns an empty array of peers and emits
no diagnostics.

#### Scenario: the bare form
- **WHEN** `@OpenAPIController struct TaskController {}` is expanded
- **THEN** the expanded source is `struct TaskController {}` with no added declaration

#### Scenario: the `spec:` form
- **WHEN** `@OpenAPIController(spec: "TaskAPI") public struct TaskController {}` is expanded
- **THEN** the expanded source is `public struct TaskController {}` with no added declaration

Pinned by: `Tests/WireOpenAPIMacrosTests/OpenAPIControllerMacroTests.swift` (`testMarkerExpandsToNothing`, `testSpecFormExpandsToNothing`).

### Requirement: The alias directs an aggregate proxy into the wire-mvc key
The `WireOpenAPI` module SHALL declare `wireOpenAPIControllerAlias` as a `WireAdapterAnnotationV1`
for annotation `OpenAPIController` with capability `.contributesAggregateProxy(to:
WireMVCKeys.routeContributors, proxyTypeName: "_WireOpenAPIContributor", proxyScope: .singleton,
groupedByAttribute: "spec")`. The controller itself SHALL NOT enter the collection; the proxy does.

#### Scenario: a controller declared with the marker and a scope annotation
- **WHEN** a target applying swift-wire's `WireBuildPlugin` and `WireOpenAPIGenPlugin` declares `@Singleton @OpenAPIController() struct TaskListController<Store: TaskStoring>` and the generated `@main` applies the graph to the router
- **THEN** `GET /api/v1/tasks` is served through the proxy collated into `WireMVCKeys.routeContributors`, and the response is `200` with a body that includes `"3"`

Pinned by: `Sources/WireOpenAPI/OpenAPIController.swift` (the alias declaration), `Fixtures/Sources/WireOpenAPIBootstrapExample/Controllers.swift` (probed by the `list` assertion of step `Serve an OpenAPI operation and a @Get route from one router` in the `Fixtures` job of `.github/workflows/build.yml`).

### Requirement: The marker takes no base path
`@OpenAPIController` SHALL accept no path argument. The prefix an operation registers under SHALL
come from the document's `servers:` block alone, applied by the runtime's
`apiPathComponentsWithServerPrefix` at registration.

#### Scenario: the document declares a server path
- **WHEN** the document declares `servers: [{url: /api/v1}]` and `paths: /tasks/{id}` and the controller carries a bare `@OpenAPIController()`
- **THEN** `GET /api/v1/tasks/42` answers `200` and `GET /tasks/42` answers `404`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `openapi` and `unprefixed` assertions).

### Requirement: The scanner records every marked struct, class and actor with its home module
`ControllerScanner` SHALL visit `StructDeclSyntax`, `ClassDeclSyntax` and `ActorDeclSyntax` nodes
and record each one carrying an attribute named exactly `OpenAPIController` as a
`DiscoveredController` whose `homeModule` is the `--module` name its source file was passed under,
whose `spec` is the value of the `spec:` argument when that argument is a plain string literal, and
whose `seed` is the type named by `@Scoped(seed: S.self)` when present. Any other `spec:` expression,
such as a constant or an interpolated literal, is recorded as no `spec`, so the controller is grouped
as if bare with no diagnostic, which is tracked as a defect in
https://github.com/swift-wire/wire-open-api/issues/81.

#### Scenario: a public struct in a dependency module
- **WHEN** the plugin passes `--module OrdersAPI OrderController.swift` and that file declares `@Scoped(seed: HTTPRequest.self) @OpenAPIController(spec: "OrdersAPI") public struct OrderController: Sendable`
- **THEN** the discovered controller has `typeName == "OrderController"`, `homeModule == "OrdersAPI"`, `spec == "OrdersAPI"` and `seed == "HTTPRequest"`

Pinned by: `Fixtures/Sources/OrdersAPI/OrderController.swift` (built by the `Build` step of the `Fixtures` job in `.github/workflows/build.yml`). The `seed` reading is observed at runtime by the `scope: order trace for /api/v2/orders/7` log assertion of the same job.

### Requirement: The bare form means the document beside the controller
WireOpenAPIGen SHALL group each controller under `controller.spec ?? controller.homeModule`. For a
bare `@OpenAPIController()` the group is therefore the module the controller is declared in, not the
module being compiled. When that group equals the compiling module the document is the one passed as
`--spec`; otherwise it is the one passed as `--spec-module <group> <document>`.

#### Scenario: a bare controller in the compiling target
- **WHEN** `TaskController` is declared with a bare `@OpenAPIController()` in `WireOpenAPIBootstrapExample`, the module passed first under `--module`
- **THEN** it is grouped under `WireOpenAPIBootstrapExample` and compiled against the document passed as `--spec`, so `GET /api/v1/tasks/42` serves it

#### Scenario: a bare controller in a dependency that owns its document
- **WHEN** `OrderController` is declared in `OrdersAPI` with a bare `@OpenAPIController()` in place of the `spec:` form
- **THEN** it is grouped under `OrdersAPI`, the module its file was passed under, and compiled against the document passed as `--spec-module OrdersAPI`

Pinned by: `Sources/WireOpenAPIGen/main.swift` (the `byGroup` loop), `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `openapi` assertion). The second scenario is pinned by nothing yet.

### Requirement: `spec:` names the module owning the generated `APIProtocol`
`@OpenAPIController(spec: "M")` SHALL group the controller under `M` regardless of where the
controller is declared. When `M` is not the compiling module, WireOpenAPIGen SHALL compile that group
against the document passed as `--spec-module M <document>`, qualifying the generated types as
`M.APIProtocol`, `M.Operations`, `M.Components` and `M.Servers`; when `M` names the compiling module,
the group is treated exactly as the bare form, compiled against `--spec` with nothing qualified.

#### Scenario: a controller in the app implementing a dependency's document
- **WHEN** `OrderSummaryController` is declared in `WireOpenAPIBootstrapExample` with `@OpenAPIController(spec: "OrdersAPI")` and implements `listOrders`
- **THEN** `GET /api/v2/orders` answers `200` with a body containing `"item-7"` and `"item-9"`, and `GET /api/v2/tasks` answers `404`

Pinned by: `Fixtures/Sources/WireOpenAPIBootstrapExample/Controllers.swift`, `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `summary` and `crossed2` assertions).

### Requirement: Every controller in a group extends one proxy
WireOpenAPIGen SHALL name the proxy for a group `_WireOpenAPIContributor_<Group>`, where `<Group>`
is the group's module name with every character that is not a letter or a number replaced by `_`,
and SHALL emit exactly one `extension _WireOpenAPIContributor_<Group>: RouteContributor` per group
carrying every operation of every controller in it.

#### Scenario: three controllers on the compiling target's document
- **WHEN** `TaskController`, `TaskListController` and `GatedTaskController` all carry a bare `@OpenAPIController()` in `WireOpenAPIBootstrapExample`
- **THEN** the emitted file contains one `extension _WireOpenAPIContributor_WireOpenAPIBootstrapExample: RouteContributor` registering `getTask`, `authorizedTask`, `listTasks`, `summariseTask`, `createTask`, `deleteTask`, `replaceTask` and `gatedTask`

#### Scenario: two controllers in two modules on one document
- **WHEN** `OrderController` in `OrdersAPI` and `OrderSummaryController` in the app both resolve to group `OrdersAPI`
- **THEN** the emitted file contains one `extension _WireOpenAPIContributor_OrdersAPI: RouteContributor` registering `getOrder` and `listOrders`, and `GET /api/v2/orders/7` and `GET /api/v2/orders` both answer `200`

Pinned by: `Sources/WireOpenAPIGen/main.swift` (`proxyTypeName(for:)`), `.github/workflows/build.yml` (`Fixtures` job, `Build` step, and the `order` and `summary` assertions of step `Serve an OpenAPI operation and a @Get route from one router`).

### Requirement: The witness reads the proxy's subject fields by the subject-count rule
The emitted witness SHALL read an app-scoped subject from `self._wireSubject` and enter a
request-scoped subject's scope through `self._wireEnterScope(request)` when the group holds one
controller, and from `self._wireSubject_<TypeName>` and `self._wireEnterScope_<TypeName>(request)`
when it holds more than one.

#### Scenario: a group of three
- **WHEN** the `WireOpenAPIBootstrapExample` group holds `TaskController`, `TaskListController` and `GatedTaskController`
- **THEN** the terminal for `getTask` calls `self._wireEnterScope_TaskController(request)` and the template conformer is built from `self._wireSubject_TaskListController`

Pinned by: `Sources/WireOpenAPIGen/DirectDispatchEmission.swift` (`subjectsAreLabelled`, `proxySubjectField`, `proxyScopeEntry`), `.github/workflows/build.yml` (`Fixtures` job, `Build` step). The single-controller spelling is pinned by nothing yet.

### Requirement: A `spec:` naming no dependency with a document is a build error
When a controller's `spec:` value is neither the compiling module nor a module passed with
`--spec-module`, WireOpenAPIGen SHALL write
`<file>:<line>: error: @OpenAPIController(spec: "<M>") names the module owning the generated APIProtocol, and no dependency of this target is called '<M>'. <available> For the document beside this controller, use the bare @OpenAPIController().`
to standard error and exit with status 1, where `<available>` is
`This target depends on no module carrying an OpenAPI document.` when no `--spec-module` was passed
and `Modules carrying one: <sorted names>.` otherwise. The message and its location are taken from
the first controller discovered in the group (the compiling module's sources are scanned first), so
this message is written only when that controller carries `spec:`, which is tracked as a defect in
https://github.com/swift-wire/wire-open-api/issues/80.

#### Scenario: a typo in the module name
- **WHEN** a controller declares `@OpenAPIController(spec: "OrderAPI")` and the only `--spec-module` is `OrdersAPI`
- **THEN** the generator exits 1 with `error: @OpenAPIController(spec: "OrderAPI") names the module owning the generated APIProtocol, and no dependency of this target is called 'OrderAPI'. Modules carrying one: OrdersAPI. For the document beside this controller, use the bare @OpenAPIController().`

Pinned by: nothing yet.

### Requirement: A bare controller in a dependency carrying no document is a build error
When a bare `@OpenAPIController()` is declared in a module other than the compiling one and no
`--spec-module` names that module, WireOpenAPIGen SHALL write
`<file>:<line>: error: '<Type>' is declared in module '<M>', which carries no OpenAPI document — a bare @OpenAPIController implements the document beside it. Put the document in '<M>', or name the module that owns the generated APIProtocol with @OpenAPIController(spec: "..."). <available>`
to standard error and exit with status 1. The message and its location are taken from the first
controller discovered in the group (the compiling module's sources are scanned first), so this message
is written only when that controller is bare; a group whose first controller carries `spec:` gets the
`spec:` message instead, which is tracked as a defect in
https://github.com/swift-wire/wire-open-api/issues/80.

#### Scenario: a library controller with no document beside it
- **WHEN** `Shared` is a Wire-aware dependency holding `@OpenAPIController() struct SharedController` and no `openapi.yaml`, and the app's own document is passed as `--spec`
- **THEN** the generator exits 1 with `error: 'SharedController' is declared in module 'Shared', which carries no OpenAPI document — a bare @OpenAPIController implements the document beside it. Put the document in 'Shared', or name the module that owns the generated APIProtocol with @OpenAPIController(spec: "..."). This target depends on no module carrying an OpenAPI document.`

Pinned by: nothing yet.

### Requirement: A compiling target with controllers and no document is a build error
When a group's document yields no operations, `diagnoseCoverage` SHALL write `<file>:<line>: error: @OpenAPIController needs the OpenAPI document to derive its routes, and none was passed (--spec).`
to standard error and exit with status 1. The same message is written whether no `--spec` was passed
for the compiling module, the document path cannot be read, or the document declares no operations.

#### Scenario: the document is missing from the target
- **WHEN** the compiling target declares a bare `@OpenAPIController()` and holds no `.yaml`, `.yml` or `.json` source other than `openapi-generator-config.yaml` and `wire-openapi.yaml`
- **THEN** the generator exits 1 with the message above, reported at the first controller's declaration line

Pinned by: nothing yet.

### Requirement: A controller is app-scoped unless it carries `@Scoped(seed:)`
WireOpenAPIGen SHALL treat a controller carrying `@Scoped(seed: S.self)` as request-scoped with seed
`S` and every other controller as app-scoped. An app-scoped controller SHALL be held directly by
the proxy and reached through its subject field; a request-scoped one SHALL be constructed per
request through the proxy's scope-entry field. Whether the type is a valid graph binding is decided
by swift-wire, not by this generator.

#### Scenario: an app-scoped and a request-scoped controller on one document
- **WHEN** `TaskController` carries `@Scoped(seed: HTTPRequest.self)` and `TaskListController` carries `@Singleton`
- **THEN** `GET /api/v1/tasks/42` logs `scope: constructed for /api/v1/tasks/42` and `GET /api/v1/tasks` logs no `scope: constructed for /api/v1/tasks` line

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `scope log` assertions and the `an app-scoped controller's operation entered a request scope` check).

### Requirement: Generic controllers are accepted and their parameters renamed in the conformer
WireOpenAPIGen SHALL accept a controller with a generic parameter clause, carry each parameter's
inherited type into the conformer, and rename the parameters of the controller at index `i` in the
group with the prefix `_wireC<i>`, so that two controllers each declaring `Store` do not collide.

#### Scenario: two controllers both generic over `Store`
- **WHEN** `TaskController<Store: TaskStoring>` and `TaskListController<Store: TaskStoring>` share a group
- **THEN** the conformer is declared `struct Conformer<_wireC0Store: TaskStoring, _wireC1Store: TaskStoring>: APIProtocol` and holds `_wireSubject_TaskController: TaskController<_wireC0Store>?` and `_wireSubject_TaskListController: TaskListController<_wireC1Store>`

Pinned by: `Sources/WireOpenAPIGen/ConformerGenerics.swift` (`genericPrefix`, `conformerGenericClause`), `Fixtures/Sources/WireOpenAPIBootstrapExample/Controllers.swift` (built by the `Build` step of the `Fixtures` job in `.github/workflows/build.yml`).

### Requirement: A generic `where` clause on a controller is refused
`rejectGenericWhereClauses` SHALL, for any controller in the group whose declaration carries a
generic `where` clause, write
`<file>:<line>: error: '<Type>' has a generic `where` clause, which the emitted conformer cannot reproduce: it renames the controller's generic parameters, and rewriting a clause that names them would mean editing constraint syntax by substitution. Write the constraint on the parameter itself instead — `<Store: TaskStoring>`.`
to standard error and exit with status 1.

#### Scenario: a constraint written in a `where` clause
- **WHEN** a controller is declared `struct TaskController<Store> where Store: TaskStoring`
- **THEN** the generator exits 1 with the message above, reported against the controller's own file and line

Pinned by: nothing yet.

### Requirement: The controller does not declare `APIProtocol` conformance
A controller SHALL NOT need to conform to `APIProtocol`. The conformance SHALL be carried by the
generated `Conformer` struct inside the spec's namespace, which forwards each operation to the
controller that declared it.

#### Scenario: the fixture controllers
- **WHEN** `TaskController`, `TaskListController`, `GatedTaskController`, `OrderController` and `OrderSummaryController` are declared with no `: APIProtocol` clause
- **THEN** the fixture builds, so the generated `Conformer` of each document satisfies `APIProtocol`

Pinned by: `Fixtures/Sources/WireOpenAPIBootstrapExample/Controllers.swift`, `Fixtures/Sources/OrdersAPI/OrderController.swift` (built by the `Build` step of the `Fixtures` job in `.github/workflows/build.yml`).

## Related specifications

- [operation-forms](../operation-forms/spec.md)
- [route-mounting](../route-mounting/spec.md)
- [error-mapping-and-scope](../error-mapping-and-scope/spec.md)
- [document-reading](../document-reading/spec.md)
- [generator-naming](../generator-naming/spec.md)
- [build-plugins-and-gen-cli](../build-plugins-and-gen-cli/spec.md)
- [swift-wire adapter-annotations](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/adapter-annotations/spec.md)
- [wire-mvc route-builder-contract](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/route-builder-contract/spec.md)
