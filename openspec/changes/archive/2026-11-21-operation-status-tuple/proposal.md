# Let a typed operation choose its documented success per call

## Why
Find-or-create (201 or 200) and accepted-or-done (202 or 204) know their status only after the
handler has run, and a typed `@Operation` could answer with one fixed success, so such operations
had to be `@RawOperation`. A typed handler may now return a status enum of the operation's
documented successes, each case carrying its response's generated headers, and the build checks the
enum against the document, so the compiler refuses an undocumented status or header. There is no
`Proposals/` document; the argument is in the implementing pull request,
<https://github.com/swift-wire/wire-open-api/pull/99>.
Tracked by <https://github.com/swift-wire/wire-open-api/issues/98>.

## What Changes
- A typed operation may return `(status:body:)` or `(headers:body:)`, or, for a bodiless response, the status enum or the generated `Headers` bare.
- A status is an author-declared enum whose cases WireOpenAPIGen checks are exactly the operation's documented 2xx responses, each carrying exactly its response's generated `Headers` when that response declares any.
- Without a status, returned headers must be exactly the one success's generated `Headers`, and a response with a required header must be given them.
- `HTTPResponse.Status`, `HTTPFields`, WireMVC's `(status:headers:…)` shapes, and enums or payloads that differ from the document are build-time errors naming the type to write.
- The forwarder switches over the enum exhaustively and passes each case's headers into the generated response, with no run-time header code; headers of any schema work.
- The "several successes" diagnostic offers a status enum as a third remedy.
- Operation diagnostics name the owning controller's file, fixing <https://github.com/swift-wire/wire-open-api/issues/87>.
- The route terminal no longer lets a catch-all mapping answer a response that failed validation, fixing <https://github.com/swift-wire/wire-open-api/issues/91>.
