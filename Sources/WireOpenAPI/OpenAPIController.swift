import Wire

// The controller collation feature: the `@OpenAPIController` marker and its aggregate-proxy directive.

/// Marks an `APIProtocol` conformer as a Wire-managed OpenAPI controller. The build plugin collates every
/// controller sharing a `spec` onto **one** generated proxy and emits that proxy's `TransportContributor`
/// conformance, whose witness calls the generator's `registerHandlers`. So `@Singleton @OpenAPIController`
/// is all a controller needs.
///
/// A no-op peer macro: the attribute exists so it compiles and so the plugin can read it. The conformance
/// cannot be generated here — `TransportContributor` refines `Sendable`, and Swift requires a `Sendable`
/// conformance in the type's own file, so it must be attached to the plugin-emitted proxy instead.
///
/// **No base path.** The prefix operations register under belongs to the document's `servers:` block,
/// which `registerHandlers` already reads through `.defaultOpenAPIServerURL`. With controllers aggregated
/// per spec, a per-controller path would also be ambiguous the moment two disagreed.
@attached(peer)
public macro OpenAPIController() =
    #externalMacro(module: "WireOpenAPIMacros", type: "OpenAPIControllerMacro")

/// The multi-spec form. `spec` names the module owning the generated `APIProtocol` — controllers sharing
/// it land on one proxy, and each distinct value gets its own. Required only when an app serves more than
/// one document: with a single spec the bare form groups everything together.
///
/// It is a use-site argument rather than something inferred from where the controller lives, because a
/// spec's generated types and the controllers implementing it routinely live in different modules — a spec
/// in `TaskAPI`, its controllers in `TaskClusterApp`.
@attached(peer)
public macro OpenAPIController(spec: String) =
    #externalMacro(module: "WireOpenAPIMacros", type: "OpenAPIControllerMacro")

/// Directs the plugin: every `@OpenAPIController` subject sharing a `spec` collates onto one
/// `_WireOpenAPIContributor[_<Spec>]` proxy, which is what contributes to `TransportKeys.handlers`.
///
/// The aggregate — rather than a proxy per controller — is forced by the generator: `registerHandlers` is
/// emitted once per document and registers *every* operation from a single handler, so one conformer per
/// spec is the only shape that registers each operation once.
public let wireOpenAPIControllerAlias = WireAdapterAnnotationV1(
    annotation: "OpenAPIController",
    capability: .contributesAggregateProxy(
        to: TransportKeys.handlers,
        proxyTypeName: "_WireOpenAPIContributor",
        proxyScope: .singleton,
        groupedByAttribute: "spec"
    )
)
