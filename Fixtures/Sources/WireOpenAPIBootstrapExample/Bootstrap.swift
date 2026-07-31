import BasicContainers
import HTTPAPIs
import HTTPTypes
import Logging
import NIOHTTPServer
import Wire
import WireMVC
import WireMVCRouter

// The composition root. There is no `main.swift`: `@WireMVCBootstrap` makes the plugin generate the
// program entry point, which bootstraps the graph, registers **every** collated route contributor onto
// the router — the OpenAPI operation and the `@Get` alike, because after M6d.1b they are the same kind
// of thing — finalizes it, and serves.
//
// That is the gate this fixture exists for: one app, one router, one `@NotFound`, both authoring styles.

@Singleton
@WireMVCBootstrap
struct AppBootstrap {
    @Inject let config: ServerConfig

    /// Returns the *concrete* server: the proposal's `Reader`/`ResponseSender` are `~Copyable`, which a
    /// bare `some HTTPServer` opaque return can't express.
    func createServer() throws -> NIOHTTPServer {
        NIOHTTPServer(
            logger: Logger(label: "WireOpenAPIBootstrapExample"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: config.host, port: config.port),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
    }

    func createRouteBuilder<Server: HTTPServer>(
        for server: borrowing Server
    ) -> some FinalizableHTTPServerRouteBuilder<Server.RequestContext, Server.Reader, Server.ResponseSender>
    where
        Server.RequestContext: ~Copyable,
        Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable,
        Server.ResponseSender.Writer: ~Copyable
    {
        TrieRouteBuilder(for: server)
    }

    /// The fallback for unmatched requests — `@NotFound` sits on the *method*, which the generated `@main`
    /// registers via `registerNotFound` before `finalize()`. Proves the OpenAPI operations are *inside*
    /// the router rather than mounted beside it: a miss reaches this, and `/api/v1/tasks/{id}` does not.
    @NotFound
    @RawRoute
    func notFound<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
        responseSender: consuming Sender
    ) async throws where Sender.Writer: ~Copyable {
        var body = UniqueArray<UInt8>(copying: [UInt8]("no route here".utf8))
        try await responseSender.sendAndFinish(HTTPResponse(status: .notFound), buffer: &body)
    }
}

@Singleton
struct ServerConfig: Sendable {
    let host: String
    let port: Int

    @Inject init() {
        self.host = "127.0.0.1"
        self.port = 8080
    }
}
