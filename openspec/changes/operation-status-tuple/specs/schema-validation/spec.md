## MODIFIED Requirements

### Requirement: A violating response answers 500 with no body
A response check SHALL throw `WireOpenAPIResponseValidationError`, whose `httpStatus` is
`.internalServerError` and whose `httpBody` is nil. With response validation on, the forwarder's
`do` SHALL rethrow it ahead of every `@ErrorResponse` clause, so no author mapping, catch-all
included, matches it there. A catch-all (`Error` or `Swift.Error`) mapping on the operation or its
controller is also emitted into the terminal's `rejectionResponse` closure, and the terminal SHALL
not consult that closure for this error, whether it arrives bare or as a `ServerError`'s
`underlyingError`, so such an operation still answers 500 with no body.

#### Scenario: a raw operation returning an over-long field
- **WHEN** the OrdersAPI document sets `validatesResponses: true`, bounds `Order.item` with `maxLength: 60`, and `getOrder` returns an 80-character `item` for `GET /api/v2/orders/toolong`
- **THEN** the answer is `500` with a zero-length body

#### Scenario: a violating response on an operation with a catch-all
- **WHEN** an operation with response validation on maps `Swift.Error` to its documented `400`, and its handler returns a body that violates the document's schema
- **THEN** the answer is `500` with a zero-length body, not `400`

Pinned by: `Tests/WireOpenAPITests/SchemaValidationTests.swift` (`responseIs500`), `.github/workflows/build.yml` (probe `badResponse`). The terminal's refusal to consult its closure is pinned by `Tests/WireOpenAPITests/ResponseSelectionTests.swift` (`serviceBreaches`), which tests the predicate the terminal applies; no probe drives a violating response through a catch-all.
