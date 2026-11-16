# Let a typed operation choose its documented success per call

## Why
Find-or-create (201 or 200) and accepted-or-done (202 or 204) know their status only after the
handler has run, and a typed `@Operation` could answer with one fixed success, so such operations
had to be `@RawOperation`. A typed handler may now return WireMVC's response tuple, whose `status`
is an enum of the operation's documented successes that the build checks against the document, so
the compiler refuses an undocumented status. There is no `Proposals/` document; the argument is in
the implementing pull request, <https://github.com/swift-wire/wire-open-api/pull/99>.
Tracked by <https://github.com/swift-wire/wire-open-api/issues/98>.

## What Changes
- A typed operation may return `(status:body:)`, `(status:headers:body:)`, `(status:headers:)` or `(headers:body:)`, read by label in that order.
- A tuple's `status` is an author-declared enum whose cases WireOpenAPIGen checks are exactly the operation's documented 2xx responses; the forwarder switches over it exhaustively.
- `HTTPResponse.Status`, an undeclared or ambiguous enum, cases with associated values and cases that differ from the document are build-time errors naming the declaration to write.
- Returned header fields fill the chosen response's generated `Headers`; a field it does not declare or a required header left out throws `WireOpenAPIUndocumentedResponse`, answered 500 with no body.
- The "several successes" diagnostic offers the status tuple as a third remedy.
- Operation diagnostics name the owning controller's file, fixing <https://github.com/swift-wire/wire-open-api/issues/87>.
- The route terminal no longer lets a catch-all mapping answer a service breach, fixing <https://github.com/swift-wire/wire-open-api/issues/91>.
