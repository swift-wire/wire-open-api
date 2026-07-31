import HTTPTypes
public import OpenAPIRuntime
import Synchronization

/// A `ServerTransport` that **captures** registrations instead of serving them.
///
/// The OpenAPI generator's `registerHandlers` is the only place that knows a document's operations —
/// their methods, their path templates, and the closure that decodes, dispatches and encodes each one.
/// It hands them to a transport one at a time. Feeding it this transport turns that side effect into a
/// list, which `WireOpenAPIRoutes` then registers on a WireMVC route builder.
///
/// So unified mode needs no new per-operation codegen: the operation set is discovered by *running* the
/// generated registration against a collector, not by parsing the spec.
public final class WireOpenAPIOperations: ServerTransport, Sendable {
    /// One captured operation, in the transport's own currency.
    public struct Operation: Sendable {
        public let method: HTTPRequest.Method
        public let path: String
        public let handler:
            @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
                HTTPResponse, HTTPBody?
            )
    }

    private let captured = Mutex<[Operation]>([])

    public init() {}

    /// Every operation captured so far, in registration order.
    public var operations: [Operation] { captured.withLock { $0 } }

    public func register(
        _ handler:
            @Sendable @escaping (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
                HTTPResponse, HTTPBody?
            ),
        method: HTTPRequest.Method,
        path: String
    ) throws {
        captured.withLock { $0.append(Operation(method: method, path: path, handler: handler)) }
    }
}
