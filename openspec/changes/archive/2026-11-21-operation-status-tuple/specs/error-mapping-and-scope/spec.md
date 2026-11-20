## MODIFIED Requirements

### Requirement: The terminal answers what the forwarder did not
`WireOpenAPIRoutes.invoke` SHALL answer an error thrown by the generated handler by trying, in order:
the operation's terminal `rejectionResponse` mappings against the error, unless the error or its
`ServerError.underlyingError` is a `WireOpenAPIResponseValidationError`, the service breaking its
own document; then, when the error or its `ServerError.underlyingError` is a
`DecodingError`, the converted `WireOpenAPIRequestValidationError` against the same mappings and
otherwise its own 422 answer; then any `HTTPResponseConvertible` conformance, which is how
`ServerError` answers and how a response validation failure answers 500 with no body; and otherwise
it SHALL rethrow.

#### Scenario: malformed JSON on an operation mapping the validation error
- **WHEN** `createTask` (`POST /api/v1/tasks/new`) requires an `application/json` body and maps `WireOpenAPIRequestValidationError` to its documented 422, and `POST /api/v1/tasks/new?title=x` sends `Content-Type: application/json` with the body `not json`
- **THEN** the answer is `422`

#### Scenario: a missing body and a wrong content type
- **WHEN** `createTask` (`POST /api/v1/tasks/new`) requires an `application/json` body, and `POST /api/v1/tasks/new?title=hello` sends no body, and separately sends `Content-Type: text/plain`
- **THEN** the answers are `400` and `415`

#### Scenario: a violating response on an operation with a catch-all
- **WHEN** an operation with response validation on maps `Swift.Error` to its documented `400`, and its handler returns a body that violates the document's schema
- **THEN** the terminal does not answer with the catch-all's `400`, and the answer is `500` with a zero-length body

Pinned by: `.github/workflows/build.yml` (probes `mappedDecode`, `mappedDecodeInside`, `missingBody`, `wrongType`), `Tests/WireOpenAPITests/ServiceBreachTests.swift` (`serviceBreaches`), which tests the predicate the terminal applies to skip its mappings; no probe drives a violating response through a catch-all.
