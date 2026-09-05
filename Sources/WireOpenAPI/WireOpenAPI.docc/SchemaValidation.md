# Schema validation

The vocabulary for validating a request or response against the document — and the honest status
of it.

> Note: These types are usable directly. Whether codegen applies them per operation is tracked in
> [#49](https://github.com/swift-wire/wire-open-api/issues/49).

## The two failures

``WireOpenAPIRequestValidationError`` is the caller's fault: a request the document describes as
invalid. It is thrown inside the forwarder, where the operation's typed input exists, so
`@ErrorResponse` maps it like any other error the handler could throw.

``WireOpenAPIResponseValidationError`` is the service's: a response the document does not
describe. It is always a `500` and **never carries a body** — the caller did nothing wrong and can
do nothing about it, so there is no honest 4xx to answer with and nothing about the service's
internals to hand over. The failures are carried for logging and for `@ErrorResponse` to read,
not for the wire.

## Collecting failures

A validator collects into a ``WireOpenAPIFailureAccumulator`` rather than failing fast, so a
caller can fix every bad field in one round trip instead of one per round trip. The accumulator
caps what it keeps, which is what makes collect-all safe: a ten-thousand-element array failing a
`pattern` would otherwise produce ten thousand failures and a response body larger than the
request that caused it.

Each ``WireOpenAPIFailure`` names where the assertion was violated via
``WireOpenAPIFailureLocation``, which mirrors wire-mvc's binding-error split rather than restating
it in new terms — the vocabulary is wire-mvc's, and this type exists only because that one is a
closed set of *binding* failures with no case for "bound fine, violates the document".

## JSON paths, not Swift paths

A failure's path is the **JSON** path, and the two genuinely differ. An `allOf` member is spelled
`value1` or `value2` in the generated type but has no counterpart on the wire, because the
generated decoder decodes every member from the same decoder. A failure reached at
`meta.value1.kind` is reported as `meta.kind`, because that is where the caller can find it.

The wire shape is declared separately from the public failure type on purpose: the public type's
property names are Swift API and the JSON keys are a wire contract, and letting one rename the
other is how a refactor becomes a breaking change for every client.
