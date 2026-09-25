# Coding bridge

## Purpose

How wire-mvc's `WireMVCCoding` reaches the OpenAPI runtime, so an operation and an annotation-driven
route in one app encode dates and JSON the same way. `Configuration(wireMVCCoding:)` turns the coding
value into the swift-openapi-runtime `Configuration` each generated server is built with, and the
generated route contributor builds that configuration from the coding the composition root passes to
`registerWireRoutes(on:coding:)`. How wire-mvc selects that value with `@Coding`, and how a
controller-scope `@Coding` is kept to its own controller's routes, is specified in wire-mvc's
controllers-and-routes and linked below.

Rationale: [WireOpenAPIAdvanced](../../../Documentation/Notes/WireOpenAPIAdvanced.md).

## Requirements

### Requirement: The JSON settings map one-to-one onto `JSONEncodingOptions`
`Configuration(wireMVCCoding:)` SHALL build `jsonEncodingOptions` by inserting `.sortedKeys` when
`coding.json.sortsKeys` is true, `.withoutEscapingSlashes` when `coding.json.escapesSlashes` is false,
and `.prettyPrinted` when `coding.json.prettyPrints` is true, and nothing else.

#### Scenario: an app that asks for sorted keys
- **WHEN** the composition root provides `WireMVCCoding(json: .init(sortsKeys: true))` and selects it with `@Coding(WireMVCCoding.self)`
- **THEN** `GET /api/v1/tasks/42` answers a body whose keys arrive in the order `at`, `id`, `title`

Pinned by: `.github/workflows/build.yml` (job "Fixtures — serve and probe", step "Serve an OpenAPI operation and a @Get route from one router", assertion "the app-wide sortsKeys did not reach the OpenAPI operation") for the `sortsKeys` to `.sortedKeys` mapping only. The `escapesSlashes` to `.withoutEscapingSlashes` and `prettyPrints` to `.prettyPrinted` mappings are pinned by nothing yet.

### Requirement: Dates go through the app's `DateTranscoding`
`Configuration(wireMVCCoding:)` SHALL set `dateTranscoder` to a `DateTranscoder` whose `encode(_:)`
and `decode(_:)` forward to `coding.dates`.

#### Scenario: a coding that writes epoch seconds
- **WHEN** `Configuration(wireMVCCoding: WireMVCCoding(dates: EpochSeconds()))` is built, where `EpochSeconds.encode(_:)` returns `String(Int(date.timeIntervalSince1970))`
- **THEN** its `dateTranscoder.encode(Date(timeIntervalSince1970: 1_700_000_000))` returns `"1700000000"`, and its `dateTranscoder.decode("1700000000")` returns that same instant

#### Scenario: one instant, two kinds of route, under the default transcoder
- **WHEN** an OpenAPI operation and a WireMVC `@Get` route in the same app each return `Date(timeIntervalSince1970: 1_700_000_000)` under an app-wide coding whose `dates` is left at its ISO8601 default
- **THEN** both bodies contain `"at":"2023-11-14T22:13:20Z"`

Pinned by: nothing yet. The forwarding to `coding.dates` is measured by no test. The two-route agreement is observed by `.github/workflows/build.yml` (assertions "the OpenAPI operation did not write the fixture date as ISO8601", "the WireMVC route did not write the same instant the same way"), but swift-openapi-runtime's own default `dateTranscoder` is also `.iso8601`, so those assertions would pass without the forwarding.

### Requirement: The coding's defaults replace the runtime's defaults
An operation's server SHALL take its `dateTranscoder` and `jsonEncodingOptions` only from the
`WireMVCCoding` value it is given (`multipartBoundaryGenerator` and `xmlCoder` keep the
swift-openapi-runtime defaults), so the runtime's default `[.sortedKeys, .prettyPrinted]` SHALL NOT
apply: a coding whose `json` settings are all at their defaults yields `jsonEncodingOptions` with
neither option.

#### Scenario: an app that declares no coding
- **WHEN** the composition root declares no `@Coding`, so `WireMVCCoding.default` is passed
- **THEN** the configuration's options do not contain `.sortedKeys` or `.prettyPrinted`

Pinned by: `.github/workflows/build.yml` (assertion "the app-wide sortsKeys did not reach the OpenAPI operation", whose compact `{"at":` prefix rules out `.prettyPrinted` for a coding with `prettyPrints` left false). The `WireMVCCoding.default` case in the scenario is pinned by nothing yet.

### Requirement: A controller-tier override elsewhere does not reach operations
The route contributor WireOpenAPIGen generates SHALL build every operation's `Configuration` from the
`coding:` argument of `registerWireRoutes(on:coding:)`, so a controller-scope `@Coding` override on a
WireMVC `@Controller` does not reach OpenAPI operations.

#### Scenario: an epoch override beside an OpenAPI operation
- **WHEN** `EpochController` is `@Coding(WireMVCCoding.epoch)`, a keyed coding writing epoch seconds, and the app-wide coding writes ISO8601
- **THEN** `GET /api/v1/tasks/42` still contains `"at":"2023-11-14T22:13:20Z"`

Pinned by: `.github/workflows/build.yml` (assertion "the OpenAPI operation did not write the fixture date as ISO8601"). That the override applies to `EpochController`'s own routes and not to other WireMVC controllers is wire-mvc's behaviour, specified in wire-mvc's controllers-and-routes.

## Related specifications

- [route-mounting](../route-mounting/spec.md)
- [controller-collation](../controller-collation/spec.md)
- [operation-forms](../operation-forms/spec.md)
- [document-reading](../document-reading/spec.md)
- [build-plugins-and-gen-cli](../build-plugins-and-gen-cli/spec.md)
- [wire-mvc route-builder-contract](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/route-builder-contract/spec.md)
- [wire-mvc request-bindings](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/request-bindings/spec.md)
- [wire-mvc controllers-and-routes](https://github.com/swift-wire/wire-mvc/blob/main/openspec/specs/controllers-and-routes/spec.md)
