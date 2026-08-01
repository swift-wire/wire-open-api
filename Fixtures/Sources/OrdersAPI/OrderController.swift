import HTTPTypes
import Wire
import WireOpenAPI

// A whole spec in its own module: the document, the types swift-openapi-generator makes from it, and the
// controller implementing them. The app that serves it never sees the document — it depends on this
// module, and `@OpenAPIController(spec: "OrdersAPI")` names the module as the owner of the generated
// `APIProtocol`.
//
// Nothing here is qualified. `Operations` is unambiguous *in this module*, which is the point: the same
// spelling is ambiguous in the app, which imports this module alongside its own generated types, and the
// conformer emitted there resolves it without the author having to think about it.

/// An app-scoped dependency of this spec, proving the graph spans modules.
@Singleton
public struct OrderStore: Sendable {
    @Inject public init() {}

    public func item(for id: String) -> String { "item-\(id)" }
}

/// Request-scoped, seeded from the request — the same scope model the Tasks spec uses next door, so the
/// two documents share one scope story as well as one router.
@Scoped(seed: HTTPRequest.self)
public struct OrderTrace: Sendable {
    public let path: String

    @Inject public init(seed: HTTPRequest) {
        self.path = seed.path ?? "/"
        print("scope: order trace for \(self.path)")
    }
}

@Scoped(seed: HTTPRequest.self)
@OpenAPIController(spec: "OrdersAPI")
// Explicitly `Sendable`: a public struct gets no implicit conformance across a module boundary, and the
// proxy that holds it in the app is `Sendable`.
public struct OrderController: Sendable {
    @Inject let store: OrderStore
    @Inject let trace: OrderTrace

    @RawOperation
    public func getOrder(_ input: Operations.GetOrder.Input) async throws -> Operations.GetOrder.Output {
        .ok(.init(body: .json(.init(id: input.path.id, item: "\(store.item(for: input.path.id)) via \(trace.path)"))))
    }
}
