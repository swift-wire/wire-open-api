package import Wire
package import WireMVC

// A global `@Middleware` that contributes a response header field. It exists to prove the thing
// "one routing model, not two" requires: a global contribution must reach an `@Operation`'s response
// exactly as it reaches a `@Get` route's. An OpenAPI terminal builds its own head inside
// `WireOpenAPIRoutes.invoke`, so it takes the contributions through a wrapping sender — the same
// mechanism a `@RawRoute` uses, and for the same reason.

package enum ServedByKeys {
    package static let factory = FactoryKey()
}

@Factory(ServedByKeys.factory)
@MiddlewareFactory
package struct ServedBy<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    package typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    package typealias NextInput = Input

    package func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        return try await input.contributing { headers in
            headers.add(.set(.init("x-served-by")!, "wire-open-api"))
        } then: { input in
            try await next(input)
        }
    }
}
