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
        maximumBodySize: Int = 1_000_000
    ) async throws
    where
        Reader.ReadElement == UInt8,
        Reader.FinalElement == HTTPFields?,
        Sender.Writer: ~Copyable
    {
        try await invoke(
            Terminal(handler: handler, maximumBodySize: maximumBodySize),
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

        let (response, responseBody) = try await terminal.handler(request, body, metadata)

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
