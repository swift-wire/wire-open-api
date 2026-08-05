import BasicContainers
import Foundation
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

/// The app's coding settings, selected by `@Coding` on the bootstrap — the app-wide tier.
///
/// Unkeyed, and selected by type: this app has one app-wide coding, so there is nothing to tell apart
/// and no name to invent. `EpochCoding` below is the case a key exists for.
///
/// `sortsKeys` is the *observable* half of the M6d.6 gate. The dates agree because ISO8601 is now the
/// default on both sides, which proves the two runtimes were unified but would look the same if the
/// settings had never travelled. A key order nobody's default produces cannot: an OpenAPI operation
/// serving sorted JSON has to have read the value declared here.
@Provides
let appCoding = WireMVCCoding(json: .init(sortsKeys: true))

/// A second coding, which is what makes this a `BindingKey`: two bindings of one type need distinguishing,
/// and that is the problem swift-wire's keys already solve.
///
/// It writes dates as epoch seconds — deliberately unlike the app's ISO8601, so a route resolving to it
/// is unmistakable in a response body. `EpochController` overrides with it at controller scope.
extension WireMVCCoding {
    static let epoch = BindingKey<WireMVCCoding>()
}

struct EpochSeconds: DateTranscoding {
    func encode(_ date: Date) throws -> String { String(Int(date.timeIntervalSince1970)) }
    func decode(_ string: String) throws -> Date { Date(timeIntervalSince1970: Double(string) ?? 0) }
}

@Provides(WireMVCCoding.epoch)
let epochCoding = WireMVCCoding(dates: EpochSeconds(), json: .init(sortsKeys: true))

@Singleton
@WireMVCBootstrap
@Coding(WireMVCCoding.self)
struct AppBootstrap {
    @Inject let config: ServerConfig

    /// Returns the *concrete* server: the proposal's `Reader`/`ResponseSender` are `~Copyable`, which a
    /// bare `some HTTPServer` opaque return can't express.
    func createServer() throws -> NIOHTTPServer {
        return NIOHTTPServer(
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
