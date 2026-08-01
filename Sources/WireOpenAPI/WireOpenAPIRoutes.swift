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
    /// Thrown when a request-scoped controller's operation is called with no request in flight.
    ///
    /// A `@Scoped(seed:)` controller only exists per request, so its operations are reachable only
    /// through a served route: the terminal enters the scope and binds the subject, and the forwarder
    /// reads it. Calling the conformance directly — in a test, say — finds nothing bound. That is a
    /// deliberate cost of entering scope in the terminal rather than in the conformance, which is where
    /// WireMVC enters it and where `@ErrorResponse` can still map a failure.
    public struct OutsideRequest: Error, CustomStringConvertible {
        public let operation: String

        public init(operation: String) { self.operation = operation }

        public var description: String {
            """
            WireOpenAPI: '\(operation)' belongs to a @Scoped(seed:) controller and was called with no \
            request in flight. Its subject is constructed per request by the route terminal, so the \
            operation is reachable only through a served route.
            """
        }
    }

    /// Thrown at registration when an operation carrying route-scope `@Middleware` never matched a route
    /// the generator actually registered.
    ///
    /// The match is by `(method, path)`, and the path is composed by *this* package — the document's
    /// `paths:` key under its `servers:` prefix — while the real one is composed by
    /// `apiPathComponentsWithServerPrefix` inside the generated `registerHandlers`. Two derivations of one
    /// rule, so they can disagree. If they ever do, the switch falls through to the default branch and the
    /// route's middleware is silently dropped; this turns that into a startup failure naming the
    /// operations affected.
    public struct RouteMismatch: Error, CustomStringConvertible {
        public let operations: [String]

        /// Public because the generated witness constructs it.
        public init(operations: [String]) { self.operations = operations }

        public var description: String {
            """
            WireOpenAPI: route-scope @Middleware was declared for \(operations.joined(separator: ", ")) \
            but no registered route matched. The path this package composed from the document does not \
            match the one the generated registerHandlers used, so the middleware would not have run.
            """
        }
    }

    public typealias Operation = WireOpenAPIOperations.Operation

    /// The handler for one operation, from a conformer built for *this* request.
    ///
    /// The per-request strategy's core: rather than a conformer captured once at bootstrap reaching the
    /// request's subject through ambient state, a fresh conformer holding that subject is registered per
    /// request and its handler taken by index. Registration order is deterministic — it is generated code
    /// — so the index a route learned at bootstrap identifies the same operation now.
    ///
    /// The cost is that `registerHandlers` runs per request: it builds one closure *and one
    /// `URLComponents` parse* per operation in the whole document, whatever the request needs.
    public static func handler(
        at index: Int,
        of contributor: some TransportContributor
    ) throws -> WireOpenAPIOperations.Handler {
        let collector = WireOpenAPIOperations()
        try contributor.registerWireHandlers(on: collector)
        let captured = collector.operations
        guard index < captured.count else {
            throw RouteMismatch(operations: ["index \(index)"])
        }
        return captured[index].handler
    }

    /// Every operation `contributor` would have registered on a `ServerTransport`, captured instead.
    ///
    /// Registration itself is emitted by `WireOpenAPIGen` rather than performed here, because a
    /// `@Middleware` fold has to be **witness-local**: `wireCompose` returns the chain's *concrete*
    /// composed type, which is what lets the terminal call `withPendingContents` on the fold's final box.
    /// A runtime helper would have to erase it and could not. So this collects, the generated witness
    /// loops, and each route is registered with its own fold around `invoke`.
    public static func operations(of contributor: some TransportContributor) throws -> [Operation] {
        let collector = WireOpenAPIOperations()
        try contributor.registerWireHandlers(on: collector)
        return collector.operations
    }

    /// The terminal a generated witness calls, inside the fold. Takes the box's already-projected
    /// contents rather than the raw handler arguments, since with middleware the reader and sender reach
    /// it through `withPendingContents`.
    /// As `invoke`, but with the operation's handler supplied — so a caller can wrap it.
    ///
    /// A request-scoped controller needs its subject bound to a task-local *around the handler call*,
    /// and it cannot be bound around this whole function: `withValue` takes a non-escaping closure that
    /// only borrows its captures, while the reader and sender are `~Copyable` values this consumes.
    /// Wrapping the handler moves the binding inside, where everything captured is copyable.
    public static nonisolated(nonsending) func invoke<
        Reader: AsyncReader & ~Copyable & SendableMetatype,
        Sender: HTTPResponseSender & ~Copyable & SendableMetatype
    >(
        handler: @escaping @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
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

    public static nonisolated(nonsending) func invoke<
        Reader: AsyncReader & ~Copyable & SendableMetatype,
        Sender: HTTPResponseSender & ~Copyable & SendableMetatype
    >(
        _ operation: Operation,
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
            Terminal(handler: operation.handler, maximumBodySize: maximumBodySize),
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
