import BasicContainers
import HTTPAPIs
import HTTPTypes
import OpenAPIRuntime
public import WireMVC

/// Mounts OpenAPI operations as **WireMVC routes** — the inbound counterpart to
/// `WireMVCServerTransport`, which carries WireMVC routes out onto a `some ServerTransport`.
///
/// This is what makes an operation a route: it then sits under the same `@NotFound` fallback, the same
/// global middleware front layer, the same `@ErrorResponse` tiers and the same `@WireMVCBootstrap`
/// composition root as an annotation-driven `@Get`. An app stops having two routing models — and serving
/// on a foreign transport becomes `WireMVCServerTransport.apply`, the call it would make anyway.
///
/// What it does *not* do is change who owns request/response binding: the generator's closure still
/// decodes `Input` and encodes `Output`, so `@JSONBody`'s content-type rules and WireMVC's own decoding
/// stay separate concerns. Only the registration boundary moves.
public enum WireOpenAPIRoutes {
    /// Enter a request scope, keeping the failure rather than throwing it.
    ///
    /// Exists because of *where* scope entry sits. The generated terminal enters the scope before it calls
    /// ``invoke(handler:request:pathParameters:reader:sender:rejectionResponse:operationID:maximumBodySize:)``,
    /// and it has to: the entry produces the subject the conformer is built around, and the scope has to
    /// outlive the response so teardown can run after it. That puts the entry outside every `catch` the
    /// conformer emits, so a `@Scoped(seed:)` binding that throws — an unauthenticated request failing to
    /// build a `Caller` — used to escape to the router unmapped, which answers nothing at all. The terminal
    /// now branches on this and refuses through ``refuse(_:mapped:sender:maximumBodySize:)`` instead.
    ///
    /// A `Result` rather than a `do`/`catch` at the call site, because the generated code cannot name what
    /// it caught: the scope entry's type is a struct swift-wire synthesised, so there is no spelling for
    /// the `var` a `do`/`catch` would have to assign into. Generic over `Entry` for the same reason — the
    /// name never appears.
    public static nonisolated(nonsending) func enteringScope<Entry>(
        _ enter: () async throws -> Entry
    ) async -> Result<Entry, any Error> {
        do {
            return .success(try await enter())
        } catch {
            return .failure(error)
        }
    }

    /// Answer an error thrown *before* the terminal ran — today, one thrown entering the request scope.
    ///
    /// The same two tiers ``invoke(handler:request:pathParameters:reader:sender:rejectionResponse:operationID:maximumBodySize:)``
    /// applies to a rejection, in the same order, one level further out: the author's own `@ErrorResponse`
    /// mappings first, then the runtime's `HTTPResponseConvertible`, and otherwise the error propagates
    /// unchanged so nothing is silently swallowed.
    ///
    /// `mapped` carries the **controller-scope** mappings only, and that is a deliberate narrowing rather
    /// than an oversight. One scope entry serves every operation on the controller, so a failure entering
    /// it is not attributable to any one of them; a mapping written on a single `@Operation` was describing
    /// that operation's handler. The generator already requires a controller-scope mapping's status to be
    /// declared by *every* operation on the controller, which is exactly the condition that makes this
    /// answer describable by the document whichever operation was asked for.
    ///
    /// The request body is never read here. There is nothing to read it for — the handler will not run —
    /// and a refusal that predates the scope is the one place in this file where not draining the body is
    /// the point rather than an oversight.
    public static nonisolated(nonsending) func refuse<
        Sender: HTTPResponseSender & ~Copyable & SendableMetatype
    >(
        _ error: any Error,
        mapped rejectionResponse: (any Error) -> (HTTPResponse, HTTPBody?)?,
        sender: consuming Sender,
        maximumBodySize: Int = 1_000_000
    ) async throws where Sender.Writer: ~Copyable {
        let response: HTTPResponse
        let responseBody: HTTPBody?
        if let mapped = rejectionResponse(error) {
            (response, responseBody) = mapped
        } else if let convertible = error as? any HTTPResponseConvertible {
            response = HTTPResponse(status: convertible.httpStatus, headerFields: convertible.httpHeaderFields)
            responseBody = convertible.httpBody
        } else {
            throw error
        }
        if let responseBody {
            let collected = try await [UInt8](collecting: responseBody, upTo: maximumBodySize)
            var buffer = UniqueArray<UInt8>(copying: collected)
            try await sender.sendAndFinish(response, buffer: &buffer)
        } else {
            try await sender.sendAndFinish(response)
        }
    }

    /// The terminal a generated witness calls, inside the fold. Takes the box's already-projected
    /// contents rather than the raw handler arguments, since with middleware the reader and sender reach
    /// it through `withPendingContents`.
    ///
    /// The handler is supplied by the caller rather than looked up here: it is a call to the operation's
    /// own method on a `UniversalServer` the generated witness built for this request, which is what
    /// keeps a request-scoped subject out of ambient state.
    public static nonisolated(nonsending) func invoke<
        Reader: AsyncReader & ~Copyable & SendableMetatype,
        Sender: HTTPResponseSender & ~Copyable & SendableMetatype
    >(
        handler:
            @escaping @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
                HTTPResponse, HTTPBody?
            ),
        request: HTTPRequest,
        pathParameters: [String: Substring],
        reader: consuming Reader,
        sender: consuming Sender,
        rejectionResponse: @escaping @Sendable (any Error) -> (HTTPResponse, HTTPBody?)? = { _ in nil },
        /// Named on the failure a rejected body produces, so a caller sees which operation refused it.
        operationID: String = "",
        maximumBodySize: Int = 1_000_000
    ) async throws
    where
        Reader.ReadElement == UInt8,
        Reader.FinalElement == HTTPFields?,
        Sender.Writer: ~Copyable
    {
        try await invoke(
            Terminal(
                handler: handler,
                rejectionResponse: rejectionResponse,
                operationID: operationID,
                maximumBodySize: maximumBodySize
            ),
            request: request,
            metadata: ServerRequestMetadata(pathParameters: pathParameters),
            reader: reader,
            sender: sender
        )
    }

    /// What a matched route runs: the generator's operation closure plus the collection limit applied to
    /// both the request it reads and the response it writes.
    private struct Terminal: Sendable {
        let handler:
            @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
                HTTPResponse, HTTPBody?
            )
        /// The generated witness's `@ErrorResponse` mappings for errors only matchable out here. Carried
        /// with the handler because it is part of what this route does, not a knob on how it is invoked.
        let rejectionResponse: @Sendable (any Error) -> (HTTPResponse, HTTPBody?)?
        let operationID: String
        let maximumBodySize: Int
    }

    /// The terminal: proposal primitives in, the generator's closure in the middle, primitives out.
    ///
    /// The two currencies meet cleanly in one place — WireMVC's matched path parameters are already
    /// `[String: Substring]`, exactly what `ServerRequestMetadata` carries, so that hand-off is a
    /// pass-through with no conversion.
    /// `nonisolated(nonsending)`: it runs on the caller's isolation rather than hopping to a concurrent
    /// context, which is what lets a possibly-isolated `Reader`/`ResponseSender` conformance cross into
    /// it. The proposal's own handler signatures are written the same way.
    private static nonisolated(nonsending) func invoke<
        Reader: AsyncReader & ~Copyable & SendableMetatype,
        Sender: HTTPResponseSender & ~Copyable & SendableMetatype
    >(
        _ terminal: Terminal,
        request: HTTPRequest,
        metadata: ServerRequestMetadata,
        reader: consuming Reader,
        sender: consuming Sender
    ) async throws
    where
        Reader.ReadElement == UInt8,
        Reader.FinalElement == HTTPFields?,
        Sender.Writer: ~Copyable
    {
        // The generator's closure takes an `HTTPBody?`, so the streaming reader is collected first. A
        // one-shot collect (rather than a streaming bridge like `WireMVCServerTransport`'s) is enough
        // while every operation is a typed, known-length request; streaming inbound bodies is a later
        // refinement, and would follow the outbound bridge's rendezvous-channel shape.
        let bytes = try await WireMVCRequest.collectBody(reader, maximumSize: terminal.maximumBodySize)
        let body: HTTPBody? = bytes.isEmpty ? nil : HTTPBody(bytes)

        // The generator's machinery rejects a request it cannot decode — a missing required body,
        // malformed JSON, a path parameter of the wrong type — by throwing `ServerError`, not by
        // returning a response. In a stock deployment its *transport* maps that to a 4xx; WireMVC is the
        // transport here, and knows nothing of it, so the error would escape to the router, which has no
        // response to write and drops the connection. (Observed: `curl` reporting no reply at all.)
        //
        // `ServerError` conforms to `HTTPResponseConvertible`, so the mapping is the runtime's own and
        // not a policy invented here. Anything else propagates untouched, which keeps WireMVC's error
        // tiers in charge of errors the *handler* threw.
        let response: HTTPResponse
        let responseBody: HTTPBody?
        do {
            (response, responseBody) = try await terminal.handler(request, body, metadata)
        } catch {
            // Two tiers, in order. `rejectionResponse` is the generated witness's `@ErrorResponse`
            // mappings for errors that can only be matched out here — a `DecodingError` from the
            // deserializer, or a catch-all — supplied as a function so this stays free of policy.
            //
            // Then the runtime's own mapping, via `HTTPResponseConvertible`, which `ServerError` conforms
            // to. Anything else propagates, leaving errors the *handler* threw to the mappings emitted
            // inside the forwarder, which have already had their turn.
            // The author's own mappings first, against the error exactly as it arrived: an
            // `@ErrorResponse(DecodingError.self, …)` has always matched here and still does.
            if let mapped = terminal.rejectionResponse(error) {
                (response, responseBody) = mapped
            } else if let rejected = WireOpenAPIRequestValidationError(
                decoding: (error as? ServerError)?.underlyingError ?? error,
                operationID: terminal.operationID
            ) {
                // A body the deserializer refused. Answered as the same failure a generated validator
                // produces — 422 with a list of what was wrong — rather than as the runtime's bare 400
                // with no body, which told the caller nothing. A mapping of the validation type gets its
                // turn first, so one `@ErrorResponse` can cover both sides of the seam.
                if let mapped = terminal.rejectionResponse(rejected) {
                    (response, responseBody) = mapped
                } else {
                    response = HTTPResponse(
                        status: rejected.httpStatus,
                        headerFields: rejected.httpHeaderFields
                    )
                    responseBody = rejected.httpBody
                }
            } else if let convertible = error as? any HTTPResponseConvertible {
                response = HTTPResponse(status: convertible.httpStatus, headerFields: convertible.httpHeaderFields)
                responseBody = convertible.httpBody
            } else {
                throw error
            }
        }

        // Send the generator's `HTTPResponse` verbatim rather than rebuilding it from a status: it
        // carries the headers the operation's serializer set (`Content-Type`, and anything the spec
        // declares), which a status-only outcome would drop.
        if let responseBody {
            let collected = try await [UInt8](collecting: responseBody, upTo: terminal.maximumBodySize)
            var buffer = UniqueArray<UInt8>(copying: collected)
            try await sender.sendAndFinish(response, buffer: &buffer)
        } else {
            try await sender.sendAndFinish(response)
        }
    }
}

/// Applies an `@ErrorResponse` body closure to the error it matched.
///
/// Declared `throws` rather than `rethrows` on purpose: the generated call is always written with `try`,
/// and a `rethrows` helper called with a non-throwing closure would make that `try` warn. The author's
/// closure may or may not throw, and the generated code should not have to know which.
public func wireOpenAPIErrorBody<E, Body>(_ error: E, _ body: (E) throws -> Body) throws -> Body {
    try body(error)
}
