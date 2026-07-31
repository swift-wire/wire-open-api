import OpenAPIRuntime
import Wire

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// The controller collation feature: the `@OpenAPIController` macro, its contribution alias,
// and the base-path → `serverURL` helper the macro's generated witness calls.

/// Makes an `APIProtocol` conformer a `TransportContributor`, registering its generated
/// handlers under `path` as the transport's base `serverURL`. The controller keeps its native
/// `APIProtocol` shape; the macro generates the `registerWireHandlers` witness. Aliases
/// `@Contributes(to: TransportKeys.handlers)`, so `@Singleton @OpenAPIController("path")` is
/// all a controller needs.
@attached(extension, conformances: TransportContributor, names: named(registerWireHandlers(on:)))
public macro OpenAPIController(_ path: String) =
    #externalMacro(module: "WireOpenAPIMacros", type: "OpenAPIControllerMacro")

/// Makes an `APIProtocol` conformer a `TransportContributor`, registering its generated
/// handlers at the spec's default server URL (no base-path prefix).
@attached(extension, conformances: TransportContributor, names: named(registerWireHandlers(on:)))
public macro OpenAPIController() =
    #externalMacro(module: "WireOpenAPIMacros", type: "OpenAPIControllerMacro")

/// Tells Wire that `@OpenAPIController` aliases `@Contributes(to: TransportKeys.handlers)`, so a
/// controller needs only `@Singleton @OpenAPIController` — the plugin collates it without a
/// separate `@Contributes`.
public let wireOpenAPIControllerAlias = WireAdapterAnnotationV1(
    annotation: "OpenAPIController",
    capability: .contributes(to: TransportKeys.handlers)
)

extension WireOpenAPI {
    /// Builds the base `serverURL` for `@OpenAPIController("path")` from its path argument — the
    /// prefix the spec's operation paths register under. Public because the macro's generated
    /// witness calls it; throws if the path isn't a valid URL.
    public static func serverURL(forBasePath path: String) throws -> URL {
        try URL(validatingOpenAPIServerURL: path)
    }
}
