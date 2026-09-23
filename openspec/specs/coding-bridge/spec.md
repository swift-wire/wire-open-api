# Coding bridge

## Purpose

How wire-mvc's `WireMVCCoding` reaches the OpenAPI runtime, so an operation and an annotation-driven
route in one app encode dates and JSON the same way. `Configuration(wireMVCCoding:)` turns the coding
value into the swift-openapi-runtime `Configuration` each generated server is built with, and the
generated route contributor builds that configuration from the coding the composition root passes to
`registerWireRoutes(on:coding:)`. How wire-mvc selects that value with `@Coding` is specified in
wire-mvc and linked below.

Rationale: [WireOpenAPIAdvanced](../../../Documentation/Notes/WireOpenAPIAdvanced.md).

## Requirements

### Requirement: The JSON settings map one-to-one onto `JSONEncodingOptions`
`Configuration(wireMVCCoding:)` SHALL build `jsonEncodingOptions` by inserting `.sortedKeys` when
`coding.json.sortsKeys` is true, `.withoutEscapingSlashes` when `coding.json.escapesSlashes` is false,
and `.prettyPrinted` when `coding.json.prettyPrints` is true, and nothing else.

#### Scenario: an app that asks for sorted keys
- **WHEN** the composition root provides `WireMVCCoding(json: .init(sortsKeys: true))` and selects it with `@Coding(WireMVCCoding.self)`
- **THEN** `GET /api/v1/tasks/42` answers a body whose keys arrive in the order `at`, `id`, `title`

Pinned by: `.github/workflows/build.yml` (job "Fixtures — serve and probe", step "Serve an OpenAPI operation and a @Get route from one router", assertion "the app-wide sortsKeys did not reach the OpenAPI operation").

### Requirement: Dates go through the app's `DateTranscoding`
`Configuration(wireMVCCoding:)` SHALL set `dateTranscoder` to a `DateTranscoder` whose `encode(_:)`
and `decode(_:)` forward to `coding.dates`.

#### Scenario: one instant, two kinds of route
- **WHEN** an OpenAPI operation and a WireMVC `@Get` route in the same app each return `Date(timeIntervalSince1970: 1_700_000_000)` under the app-wide coding
- **THEN** both bodies contain `"at":"2023-11-14T22:13:20Z"`

Pinned by: `.github/workflows/build.yml` (assertions "the OpenAPI operation did not write the fixture date as ISO8601", "the WireMVC route did not write the same instant the same way").

### Requirement: The coding's defaults replace the runtime's defaults
An operation's server SHALL be configured only from the `WireMVCCoding` value it is given, so the
swift-openapi-runtime default `[.sortedKeys, .prettyPrinted]` SHALL NOT apply: a coding whose `json`
settings are all at their defaults yields `jsonEncodingOptions` with neither option.

#### Scenario: an app that declares no coding
- **WHEN** the composition root declares no `@Coding`, so `WireMVCCoding.default` is passed
- **THEN** the configuration's options do not contain `.sortedKeys` or `.prettyPrinted`

Pinned by: nothing yet.

### Requirement: A controller-tier override elsewhere does not reach operations
A controller-scope `@Coding` override on a WireMVC `@Controller` SHALL change only that controller's
routes, leaving OpenAPI operations and other controllers on the app-wide coding.

#### Scenario: an epoch override beside ISO8601 routes
- **WHEN** `EpochController` is `@Coding(WireMVCCoding.epoch)`, a keyed coding writing epoch seconds
- **THEN** `GET /epoch/tasks` contains `"at":"1700000000"`, while `GET /status/tasks` and `GET /api/v1/tasks/42` still contain `"at":"2023-11-14T22:13:20Z"`

Pinned by: `.github/workflows/build.yml` (assertions "the controller-scope @Coding override did not resolve", "a controller-scope @Coding override leaked to another controller", "the OpenAPI operation did not write the fixture date as ISO8601").

## Related specifications

- [route-mounting](../route-mounting/spec.md)
- [controller-collation](../controller-collation/spec.md)
- [operation-forms](../operation-forms/spec.md)
- [document-reading](../document-reading/spec.md)
- [build-plugins-and-gen-cli](../build-plugins-and-gen-cli/spec.md)
- [wire-mvc route-builder-contract](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/route-builder-contract/spec.md)
- [wire-mvc request-bindings](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/request-bindings/spec.md)
