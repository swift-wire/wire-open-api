import HTTPAPIs
import HTTPTypes
import Wire
import WireMVC

/// One middleware component, applied to **both** kinds of route — the shared-middleware gate. It is an ordinary
/// proposal `Middleware` and an ordinary Wire binding; nothing about it knows whether the route it wraps
/// came from an OpenAPI document or from a `@Get`. That is the whole claim of the unification: the same
/// component, not two implementations of one policy.
///
/// Factory-form (generic over the box's roles), the shape a middleware folded into a route witness takes:
/// the fold calls `create` specialised at the builder's associated types. A concrete `@Singleton`
/// middleware would have to pin the server's context/reader/sender, which Wire diagnoses.
enum RequireAPIKeyKeys {
    static let factory = FactoryKey()
}

@Factory(RequireAPIKeyKeys.factory)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the roles in order
struct RequireAPIKey<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    typealias NextInput = Input

    @Inject init() {}

    func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        let request = input.peekedRequest
        trace("apikey: \(request.method.rawValue) \(request.path ?? "/")")
        return try await next(input)
    }
}

/// A second component, applied at **route** scope to one operation only — the check that the two tiers
/// are distinguishable: `audit:` must appear for `listTasks` and not for `getTask`.
enum AuditKeys {
    static let factory = FactoryKey()
}

@Factory(AuditKeys.factory)
@MiddlewareFactory
struct Audit<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    typealias NextInput = Input

    @Inject init() {}

    func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        trace("audit: \(input.peekedRequest.path ?? "/")")
        return try await next(input)
    }
}
