# Build plugins and WireOpenAPIGen command line

## Purpose

How wire-open-api's code generation is scheduled and invoked. The package ships two build-tool
plugins: `WireOpenAPIBuildPlugin`, which runs swift-wire's `WireGen` and then `WireOpenAPIGen`, and
`WireOpenAPIGenPlugin`, which runs `WireOpenAPIGen` alone so it can be listed beside other adapters'
plugins. This spec covers which sources, documents and settings files the plugins find, the
`WireOpenAPIGen` command line they build, and `DiagnosticGoldenTool`, which holds the generator's
rejections to a checked-in table. What `WireGen` does with its arguments is specified in swift-wire.

Rationale: [WireOpenAPIAdvanced](../../../Documentation/Notes/WireOpenAPIAdvanced.md).
Documentation: [AddingWireOpenAPIToAPackage](../../../Sources/WireOpenAPI/WireOpenAPI.docc/AddingWireOpenAPIToAPackage.md).

## Requirements

### Requirement: The package vends two build-tool plugins
`Package.swift` SHALL declare the plugin products `WireOpenAPIBuildPlugin`, whose plugin target
depends on the `WireOpenAPIGen` executable and swift-wire's `WireGen` product, and
`WireOpenAPIGenPlugin`, whose plugin target depends on `WireOpenAPIGen` only. Both SHALL have the
`.buildTool()` capability.

#### Scenario: a consumer names either plugin
- **WHEN** a target lists `.plugin(name: "WireOpenAPIGenPlugin", package: "wire-open-api")`
- **THEN** SwiftPM builds `WireOpenAPIGen` for the host and runs the plugin before compiling the target

Pinned by: `Fixtures/Package.swift` (applies `WireOpenAPIGenPlugin`; built by the `Build` step of the `Fixtures` job in `.github/workflows/build.yml`).

### Requirement: A target with no Swift sources gets no commands
Both plugins SHALL return no build commands for a target that is not a source module or has no
`.swift` source files.

#### Scenario: a resource-only target
- **WHEN** a plugin is applied to a target whose only sources are `openapi.yaml` and `openapi-generator-config.yaml`
- **THEN** it schedules nothing

Pinned by: nothing yet.

### Requirement: `WireOpenAPIBuildPlugin` schedules WireGen and then WireOpenAPIGen
`WireOpenAPIBuildPlugin` SHALL return two build commands in this order: `WireGen <target>`, running
`WireGen` with outputs `_WireGraph.swift` and `_WireKeyChecks.swift` in the plugin work directory,
and `WireOpenAPIGen <target>`, running `WireOpenAPIGen` with the single output
`_WireOpenAPIHandlers.swift`. WireGen's arguments SHALL be
`<_WireGraph.swift> <_WireKeyChecks.swift> [--testing-variants] --module <Target> <sources>...`
followed by `--module <M> <sources>...` for each Wire-aware target dependency and
`--external-module <M> <sources>...` for each Wire-aware module reached through a product, with
`--testing-variants` passed only for a test target.

#### Scenario: an app applying only this plugin
- **WHEN** an executable target `App` depending on `WireOpenAPI`, `WireMVC` and `Wire` applies `WireOpenAPIBuildPlugin`
- **THEN** the build runs `WireGen App` and `WireOpenAPIGen App`, and the module compiles `_WireGraph.swift`, `_WireKeyChecks.swift` and `_WireOpenAPIHandlers.swift`

Pinned by: nothing yet.

### Requirement: `WireOpenAPIGenPlugin` schedules WireOpenAPIGen only
`WireOpenAPIGenPlugin` SHALL return exactly one build command, `WireOpenAPIGen <target>`, with the
same arguments, input files and output `_WireOpenAPIHandlers.swift` as the second command of
`WireOpenAPIBuildPlugin`.

#### Scenario: composed with the other adapters' plugins
- **WHEN** `WireOpenAPIBootstrapExample` applies `OpenAPIGenerator`, `WireBuildPlugin`, `WireMVCRouteGenPlugin` and `WireOpenAPIGenPlugin`, in that order
- **THEN** the graph is emitted once by `WireBuildPlugin`, and one router serves both `GET /api/v1/tasks/42` and `GET /status/tasks`

Pinned by: `Fixtures/Package.swift`, `.github/workflows/build.yml` (`Fixtures` job, `Build` step, and the `openapi` and `mvc` assertions of step `Serve an OpenAPI operation and a @Get route from one router`).

### Requirement: The sources of every Wire-aware direct dependency are read
For each direct dependency of the target, taking a target as itself and a product as each of its
targets, both plugins SHALL include every source module that depends on a target or product named
`Wire`, `WireMVC` or `WireOpenAPI`, once per module name, in dependency order.

#### Scenario: a dependency owning a document
- **WHEN** `WireOpenAPIBootstrapExample` depends on `OrdersAPI`, which depends on the `WireOpenAPI` and `Wire` products
- **THEN** `OrdersAPI`'s Swift sources are passed as `--module OrdersAPI …` and its `OrderController` serves `GET /api/v2/orders/7`

Pinned by: `Fixtures/Package.swift`, `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `order` assertion).

### Requirement: Documents and their settings are found among a module's source files
In the target and in each Wire-aware dependency, both plugins SHALL take as OpenAPI documents the
source files whose extension is `yaml`, `yml` or `json` and whose name is neither
`openapi-generator-config.yaml` nor `wire-openapi.yaml`; as generator configs the files named
`openapi-generator-config.yaml`; and as adapter settings the files named `wire-openapi.yaml`.

#### Scenario: a module with all three files
- **WHEN** `OrdersAPI` holds `openapi.yaml`, `openapi-generator-config.yaml` and `wire-openapi.yaml`
- **THEN** only `openapi.yaml` is passed as a document, and the other two are passed as that module's config and settings

Pinned by: `Fixtures/Sources/OrdersAPI/wire-openapi.yaml`, `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `badResponse` assertion).

### Requirement: The plugins build the WireOpenAPIGen arguments in a fixed order
Both plugins SHALL pass `WireOpenAPIGen`, in order: the output path; `--spec <document>` for each
of the target's documents; `--spec-module <M> <document>` for each dependency document;
`--spec-config <file>` and then `--spec-module-config <M> <file>` for the configs;
`--spec-settings <file>` and then `--spec-module-settings <M> <file>` for the settings files;
`--import <M>` for each Wire-aware dependency; `--module <Target>` followed by the target's Swift
sources; and `--module <M>` followed by each dependency's Swift sources.

#### Scenario: the fixture app
- **WHEN** the plugin runs for `WireOpenAPIBootstrapExample`
- **THEN** the arguments include `--spec-module OrdersAPI <…/OrdersAPI/openapi.yaml>`, `--spec-module-settings OrdersAPI <…/OrdersAPI/wire-openapi.yaml>` and `--import OrdersAPI`, and the first `--module` is `WireOpenAPIBootstrapExample`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, `Build` step, and the `order` and `badResponse` assertions of step `Serve an OpenAPI operation and a @Get route from one router`).

### Requirement: Documents, configs and settings are declared inputs
The `WireOpenAPIGen` command's `inputFiles` SHALL be the Swift sources of the target and of every
Wire-aware dependency, together with every document, config and settings file passed on the
command line, so an edit to any of them re-runs the generator.

#### Scenario: a document-only edit
- **WHEN** only `openapi.yaml` changes between two builds
- **THEN** `WireOpenAPIGen` runs again and `_WireOpenAPIHandlers.swift` is regenerated

Pinned by: nothing yet.

### Requirement: The WireOpenAPIGen command line
`WireOpenAPIGen` SHALL take its output path as the first argument and then any of
`--spec <p>`, `--spec-module <M> <p>`, `--spec-config <p>`, `--spec-module-config <M> <p>`,
`--spec-settings <p>`, `--spec-module-settings <M> <p>`, `--import <M>` and `--module <M>`; every
other argument SHALL be a Swift source belonging to the most recent `--module`, or to a module
named `""` when none has been given. The first `--module` SHALL be the compiling module. With no
arguments it SHALL write `WireOpenAPIGen: missing output path` to standard error and exit with
status 1.

#### Scenario: the invocation `DiagnosticGoldenTool` makes
- **WHEN** WireOpenAPIGen runs as `WireOpenAPIGen out.swift --spec openapi.yaml --spec-config config.yaml --module Gate Controller.swift`
- **THEN** `Gate` is the compiling module, its controllers are compiled against `openapi.yaml`, and `config.yaml` supplies the naming strategy

#### Scenario: no arguments
- **WHEN** `WireOpenAPIGen` is run with no arguments
- **THEN** it exits 1 with `WireOpenAPIGen: missing output path`

Pinned by: `Sources/DiagnosticGoldenTool/main.swift` (`run`), `Sources/DiagnosticGoldenTool/diagnostics-golden.txt`. The no-arguments case is pinned by nothing yet.

### Requirement: Each document is read with its own module's config and settings
WireOpenAPIGen SHALL read the compiling module's document with the files passed as `--spec-config`
and `--spec-settings`, and module `M`'s document with the files passed as
`--spec-module-config M` and `--spec-module-settings M`.

#### Scenario: response validation on for one document only
- **WHEN** `OrdersAPI`'s `wire-openapi.yaml` says `validatesResponses: true` and the app's own document has no `wire-openapi.yaml`
- **THEN** `GET /api/v2/orders/toolong` answers `500` with no body, while the app's Tasks operations are unchecked

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Serve an OpenAPI operation and a @Get route from one router`, the `badResponse` assertion).

### Requirement: The output is written only when generation succeeds
WireOpenAPIGen SHALL write the output file once, after every group has been emitted, beginning with
the line `// Generated by WireOpenAPIGen — do not edit.`. A diagnostic that exits with status 1
SHALL leave the output file unwritten.

#### Scenario: a rejected case
- **WHEN** `DiagnosticGoldenTool` runs the `route-scope/status-not-declared` case
- **THEN** WireOpenAPIGen exits non-zero and the case is recorded as `rejected:` with its message

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`route-scope/status-not-declared`), `.github/workflows/build.yml` (`Fixtures` job, `Build` step).

### Requirement: `DiagnosticGoldenTool` runs each case through the built generator
`DiagnosticGoldenTool` SHALL, for each case, lay out `openapi.yaml`, `Controller.swift`,
`config.yaml` (`generate: [types, server]`, `accessModifier: internal`, `namingStrategy: idiomatic`)
and, when the case carries settings, `wire-openapi.yaml` in a temporary directory; run
`WireOpenAPIGen out.swift --spec openapi.yaml --spec-config config.yaml [--spec-settings wire-openapi.yaml] --module Gate Controller.swift`
there; and record `accepted` for exit status 0, or `rejected: <stderr>` otherwise, under a
`## <case name>` heading and a `# <summary>` line.

#### Scenario: an accepted case
- **WHEN** the case `accepted/per-operation-forms-are-the-remedy-for-disagreement` runs
- **THEN** its entry in the table is `accepted`

Pinned by: `Sources/DiagnosticGoldenTool/diagnostics-golden.txt` (`accepted/per-operation-forms-are-the-remedy-for-disagreement`).

### Requirement: `DiagnosticGoldenTool --check` compares the table verbatim
With `--check`, `DiagnosticGoldenTool` SHALL rebuild the table and compare it with
`Sources/DiagnosticGoldenTool/diagnostics-golden.txt` byte for byte. On a difference it SHALL write
`WireOpenAPIGen no longer answers diagnostics-golden.txt as recorded.` with a `was:`/`now:` pair per
differing line and exit 1; on a match it SHALL print `diagnostics match the golden (<N> cases).`.
Without `--check` it SHALL rewrite the file.

#### Scenario: CI
- **WHEN** the `Fixtures` job runs `swift build --product WireOpenAPIGen` and then `swift run DiagnosticGoldenTool --check`
- **THEN** the step fails if any case's exit outcome or standard-error text differs from the table

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Check the diagnostics WireOpenAPIGen rejects with`).

### Requirement: `DiagnosticGoldenTool` locates the generator and refuses a stale one
`DiagnosticGoldenTool` SHALL use `WIRE_OPENAPI_GEN_PATH` when set, and otherwise the first executable
among `WireOpenAPIGen` beside its own binary, `.build/out/Products/Debug`, `.build/debug`,
`.build/release`, `Fixtures/.build/out/Products/Debug` and `Fixtures/.build/debug`. When none exists
it SHALL fail with a message beginning `cannot find a built WireOpenAPIGen. Build it first:`. When
any `.swift` file under `Sources/WireOpenAPIGen` has a later modification time than the binary it
SHALL fail with a message stating the binary `is older than Sources/WireOpenAPIGen` and naming
`swift build --product WireOpenAPIGen`.

#### Scenario: a diagnostic edited without rebuilding
- **WHEN** `Sources/WireOpenAPIGen/Diagnostics.swift` is saved after the last `swift build` and `swift run DiagnosticGoldenTool` is run
- **THEN** the tool exits 1 before running any case and does not rewrite the golden

Pinned by: nothing yet.

## Related specifications

- [controller-collation](../controller-collation/spec.md), for how the `--module` groups become controller groups and the error when no `--spec` is passed
- [document-reading](../document-reading/spec.md)
- [route-mounting](../route-mounting/spec.md), for the imports and witnesses written to the output file
- [schema-validation](../schema-validation/spec.md)
- [generator-naming](../generator-naming/spec.md)
- [swift-wire build-plugin-and-wiregen-cli](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/build-plugin-and-wiregen-cli/spec.md)
- [wire-mvc build-plugins-and-routegen-cli](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/build-plugins-and-routegen-cli/spec.md)
