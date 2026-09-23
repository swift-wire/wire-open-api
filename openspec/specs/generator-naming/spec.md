# Generator naming parity

## Purpose

`WireOpenAPINaming` reproduces the names swift-openapi-generator gives the symbols it emits, so that
WireOpenAPIGen can spell `Operations.<X>`, `input.path.<y>` and an `Output` case such as `.created`
without reading the generator's output. It is a transcription of two internal parts of the
generator, `SafeNameGenerator` and `HTTPStatusCodes`, held to the generator's real behaviour by golden
tables that `NamingGoldenTool` produces by running the generator itself.

Rationale: [WireOpenAPIAdvanced](../../../Documentation/Notes/WireOpenAPIAdvanced.md).

## Requirements

### Requirement: Two naming strategies, defensive by default
`GeneratorNamingStrategy` SHALL be a `String`-backed enum with the cases `defensive` and
`idiomatic`, whose raw values are the `namingStrategy` spellings in `openapi-generator-config.yaml`.
`GeneratorNamingStrategy.generatorDefault` SHALL be `.defensive`.

#### Scenario: the default
- **WHEN** code reads `GeneratorNamingStrategy.generatorDefault`
- **THEN** it is `.defensive`

#### Scenario: a config value
- **WHEN** `GeneratorNamingStrategy(rawValue: "idiomatic")` is evaluated
- **THEN** it is `.idiomatic`

Pinned by: `Tests/WireOpenAPINamingTests/GeneratorSafeNamesTests.swift` (`generatorDefaultIsDefensive`).

### Requirement: The transcription reproduces the generator's names
`GeneratorSafeNames.swiftTypeName(for:strategy:)` and `GeneratorSafeNames.swiftMemberName(for:strategy:)`
SHALL return, for every row of `Tests/WireOpenAPINamingTests/naming-golden.tsv`, the type and member
names that row records for each strategy.

#### Scenario: an operationId under each strategy
- **WHEN** `swiftTypeName(for: "getTask", strategy:)` is called with `.idiomatic` and with `.defensive`
- **THEN** the results are `GetTask` and `getTask`

#### Scenario: a hyphenated header name
- **WHEN** `swiftMemberName(for: "X-Request-Id", strategy:)` is called with `.idiomatic` and with `.defensive`
- **THEN** the results are `xRequestId` and `X_hyphen_Request_hyphen_Id`

Pinned by: `Tests/WireOpenAPINamingTests/GeneratorSafeNamesTests.swift` (`theGoldenTableLoaded`, `reproducesTheGenerator`, `theCasesTheShimDependsOn`).

### Requirement: The defensive strategy escapes characters a Swift identifier cannot hold
Under `.defensive`, the type and member names SHALL be the same string: the documented name with
each character that is not a letter, digit or `_` replaced by `_<entity>_`, where `<entity>` is its
HTML entity name from `specialCharsMap` or `x` followed by its upper-case hexadecimal scalar value;
a leading digit prefixed with `_`; and a result that is one of `keywords` prefixed with `_`.

#### Scenario: a separator and a symbol
- **WHEN** the documented names are `get-task` and `$filter`
- **THEN** the defensive names are `get_hyphen_task` and `_dollar_filter`

#### Scenario: a leading digit and a keyword
- **WHEN** the documented names are `9lives` and `class`
- **THEN** the defensive names are `_9lives` and `_class`

#### Scenario: a standard-library name not in the keyword list
- **WHEN** the documented name is `Optional`
- **THEN** the defensive name is `Optional`

Pinned by: `Tests/WireOpenAPINamingTests/GeneratorSafeNamesTests.swift` (`reproducesTheGenerator`), `Tests/WireOpenAPINamingTests/naming-golden.tsv`.

### Requirement: The idiomatic strategy camel-cases, then applies the defensive rules
Under `.idiomatic`, the type name SHALL be upper camel case and the member name lower camel case,
with words split at `_`, `-`, space, `/` and `+`, and an all-upper-case documented name lower-cased
word by word. The camel-cased result SHALL then pass through the defensive transform, so keywords
and leading digits are prefixed as there.

#### Scenario: separated and all-upper-case names
- **WHEN** the documented names are `GET_TASK` and `user-id`
- **THEN** the idiomatic type names are `GetTask` and `UserId` and the member names `getTask` and `userId`

#### Scenario: an initialism
- **WHEN** the documented name is `HTTPProxyURL`
- **THEN** the idiomatic type name is `HTTPProxyURL` and the member name `httpProxyURL`

#### Scenario: a keyword
- **WHEN** the documented name is `class`
- **THEN** the idiomatic type name is `Class` and the member name `_class`

Pinned by: `Tests/WireOpenAPINamingTests/GeneratorSafeNamesTests.swift` (`reproducesTheGenerator`), `Tests/WireOpenAPINamingTests/naming-golden.tsv`.

### Requirement: Status codes map to the generator's `Output` case names
`GeneratorStatusNames.safeName(for:)` SHALL return the generator's named case for each status it
names (for example `200` is `ok`, `201` is `created`, `422` is `unprocessableContent`) and
`code<N>` for every other status. For `100` it SHALL return `` `continue` `` with the backticks, as
the generator emits it.

#### Scenario: a named status
- **WHEN** `GeneratorStatusNames.safeName(for: 204)` is called
- **THEN** it returns `noContent`

#### Scenario: an unnamed status
- **WHEN** `GeneratorStatusNames.safeName(for: 102)` is called
- **THEN** it returns `code102`

#### Scenario: a keyword
- **WHEN** `GeneratorStatusNames.safeName(for: 100)` is called
- **THEN** it returns `` `continue` ``

Pinned by: `Tests/WireOpenAPINamingTests/GeneratorSafeNamesTests.swift` (`statusTableLoaded`, `statusCaseMatchesTheGenerator`), `Tests/WireOpenAPINamingTests/status-golden.tsv`.

### Requirement: The naming table is produced by running the generator
`swift run NamingGoldenTool` SHALL write a document with one operation per non-comment line of
`Tests/WireOpenAPINamingTests/naming-corpus.txt` (that line as its `operationId`), plus a path
parameter of that name for every line containing none of `{`, `}` and `/`, run
swift-openapi-generator over it under `defensive` and `idiomatic`, read the `Operations` enum names
and `Path` member names back out of the emitted `Types.swift`, and write them to
`naming-golden.tsv` as `documented`, `defensive.type`, `defensive.member`, `idiomatic.type`,
`idiomatic.member`, with `-` for a member a documented name cannot have.

#### Scenario: a name that cannot be a path parameter
- **WHEN** the corpus holds `get/task`
- **THEN** its row records `get_sol_task` and `GetTask` as the type names and `-` in both member columns

Pinned by: `Tests/WireOpenAPINamingTests/naming-golden.tsv`, `.github/workflows/build.yml` (`Fixtures` job, step `Check the naming golden table against the real generator`).

### Requirement: The status table covers 100 through 599
`NamingGoldenTool` SHALL write a document declaring one operation per status from `100` to `599`,
run the generator over it with `namingStrategy: idiomatic`, and write the first non-`undocumented`
`Output` case of each operation to `status-golden.tsv` as `<status>\t<case>`, 500 rows in all. A
status for which no case is found SHALL fail the tool with
`the generator emitted no Output case for status <N>`.

#### Scenario: the table's length
- **WHEN** the unit tests load `status-golden.tsv`
- **THEN** it holds exactly 500 rows

Pinned by: `Tests/WireOpenAPINamingTests/GeneratorSafeNamesTests.swift` (`statusTableLoaded`).

### Requirement: `--check` fails when the generator no longer agrees with a table
With `--check`, `NamingGoldenTool` SHALL regenerate both tables without writing them and compare
each with the checked-in file. On any difference it SHALL write
`The generator no longer agrees with <file>.` followed by
`Sources/WireOpenAPINaming transcribes its <label>; it has diverged.` and a `was:`/`now:` pair for
each differing row, where `<label>` is `safe-name transform` or `status-code table`, and exit 1. When
both match it SHALL print `golden tables match the generator (<N> names, 500 statuses).` and exit 0.

#### Scenario: CI against the fixture's generator checkout
- **WHEN** the `Fixtures` job runs `swift run NamingGoldenTool --check` with `OPENAPI_GENERATOR_PATH` set to `Fixtures/.build/checkouts/swift-openapi-generator`
- **THEN** the step passes only if the generator the fixture resolved emits the names both tables record

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Check the naming golden table against the real generator`).

### Requirement: The tool finds the generator through `OPENAPI_GENERATOR_PATH`
`NamingGoldenTool` SHALL run the generator as
`swift run --package-path <generator> swift-openapi-generator generate`, where `<generator>` is the
`OPENAPI_GENERATOR_PATH` environment variable or, when that is unset,
`Fixtures/.build/checkouts/swift-openapi-generator` under the repository root. A generator exit
other than 0 SHALL fail the tool with `the generator failed for <strategy>:` and the tail of its
standard error.

#### Scenario: run locally after building the fixtures
- **WHEN** `swift build` has been run in `Fixtures` and `swift run NamingGoldenTool` is run with no environment override
- **THEN** it runs the generator checked out under `Fixtures/.build/checkouts/swift-openapi-generator`

Pinned by: `.github/workflows/build.yml` (`Fixtures` job, step `Check the naming golden table against the real generator`).

### Requirement: The transcribed files carry the upstream attribution
`Sources/WireOpenAPINaming/GeneratorSafeNames.swift` and `Sources/WireOpenAPINaming/GeneratorStatusNames.swift`
SHALL carry the SwiftOpenAPIGenerator copyright line above this project's own and name the upstream
file each transcribes, and `NOTICE` SHALL list both files with those upstream sources. Both files
SHALL be excluded from SwiftLint in `.swiftlint.yml` and from swift-format by
`// swift-format-ignore-file`.

#### Scenario: the licence-header check
- **WHEN** the `LicenceHeaders` job runs `Scripts/check-license-headers.sh`
- **THEN** both files pass with the SPDX identifier within their first five lines and this project's copyright line within their first twelve

Pinned by: `.github/workflows/build.yml` (`LicenceHeaders` job, the SPDX and project copyright lines). The upstream attribution and `NOTICE` entries are pinned by nothing yet.

## Related specifications

- [operation-forms](../operation-forms/spec.md), for where WireOpenAPIGen spells generated names with these functions
- [document-reading](../document-reading/spec.md)
