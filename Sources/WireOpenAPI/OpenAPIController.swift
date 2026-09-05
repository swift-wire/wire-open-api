// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import Wire
// Plain: `WireMVCKeys` is named in the alias's *value*, not in the type of anything public here.
import WireMVC

// The controller collation feature: the `@OpenAPIController` marker and its aggregate-proxy directive.

/// Marks an `APIProtocol` conformer as a Wire-managed OpenAPI controller. The build plugin collates every
/// controller sharing a `spec` onto **one** generated proxy and emits that proxy's `RouteContributor`
/// conformance, which mounts the document's operations as WireMVC routes. So `@Singleton
/// @OpenAPIController` is all a controller needs.
///
/// A no-op peer macro: the attribute exists so it compiles and so the plugin can read it. The conformance
/// cannot be generated here — `RouteContributor` refines `Sendable`, and Swift requires a `Sendable`
/// conformance in the type's own file, so it must be attached to the plugin-emitted proxy instead.
///
/// **No base path.** The prefix operations register under belongs to the document's `servers:` block,
/// which the runtime's `apiPathComponentsWithServerPrefix` applies. With controllers aggregated per spec,
/// a per-controller path would also be ambiguous the moment two disagreed.
///
/// The bare form means **the document beside this controller** — the one in the module the controller is
/// declared in. A document owned by a *different* module is named with `spec:` below.
///
/// "Beside this controller", not "in the target being compiled": those coincide for an app that generates
/// its own document, and diverge the moment a spec and its controllers ship together in a library, which
/// is the ordinary way to serve one document from several runtimes. Resolving against the compiling target
/// would make the bare form mean something the author cannot see from the file they are reading — the
/// answer would depend on which executable happened to pull the library in.
@attached(peer)
public macro OpenAPIController() =
    #externalMacro(module: "WireOpenAPIMacros", type: "OpenAPIControllerMacro")

/// The other-module form. `spec` names the module owning the generated `APIProtocol` — controllers sharing
/// it land on one proxy, and each distinct value gets its own. Use it when the document lives somewhere
/// other than beside the controller; for the one beside it, use the bare form above.
///
/// It stays a use-site argument, because a spec's generated types and the controllers implementing them
/// genuinely can live in different modules — a document in `TaskAPI`, its controllers in `TaskClusterApp`.
/// Where a controller is declared therefore *narrows* which document it implements without settling it,
/// which is why the bare form defaults to the neighbouring document and this form overrides.
///
/// A value naming no such dependency is an error. It is never taken as a label and quietly resolved
/// against some other document: that would compile against the wrong one and report it as a missing
/// `@RawOperation` for operations the author never wrote.
@attached(peer)
public macro OpenAPIController(spec: String) =
    #externalMacro(module: "WireOpenAPIMacros", type: "OpenAPIControllerMacro")

/// Directs the plugin: every `@OpenAPIController` subject sharing a `spec` collates onto one
/// `_WireOpenAPIContributor[_<Spec>]` proxy, which contributes to **`WireMVCKeys.routeContributors`** —
/// the same key `@Controller` uses. An operation is a route, so it serves under the same router,
/// `@NotFound`, error tiers, middleware layer and composition root as an annotation-driven one.
///
/// The aggregate — rather than a proxy per controller — follows the document: a spec's operations are
/// implemented against one generated `APIProtocol`, so one conformer per spec is the shape that mounts
/// each operation exactly once. Several controllers may share that spec, each contributing the
/// operations it declares; scoping and controller-scope `@Middleware` remain per controller, and the
/// proxy holds or bridges each subject independently.
public let wireOpenAPIControllerAlias = WireAdapterAnnotationV1(
    annotation: "OpenAPIController",
    capability: .contributesAggregateProxy(
        to: WireMVCKeys.routeContributors,
        proxyTypeName: "_WireOpenAPIContributor",
        proxyScope: .singleton,
        groupedByAttribute: "spec"
    )
)

/// Marks a hand-written operation handler — one taking the generated `Operations.X.Input` and returning
/// its `Output` — and declares **which** operation it implements.
///
/// Identity has to be declared rather than recovered. The generated protocol requirement is named from
/// the operationId, so a method called `getTask` does implement `getTask` — but only after the
/// generator's safe-name transform, which is identity for `getTask` and not for `get-task` or
/// `list_tasks`. Recovering the id by reversing that transform would quietly match nothing for any spec
/// whose operationIds aren't already Swift identifiers, and route-scope `@Middleware` on such a method
/// would silently never apply. Declaring it is the same resolution `@RawRoute`'s explicit roles and
/// `@MiddlewareFactory`'s role mapping reached.
///
/// Bare, the method's own name is the operationId — true by construction unless the method is renamed.
@attached(peer)
public macro RawOperation() =
    #externalMacro(module: "WireOpenAPIMacros", type: "OpenAPIControllerMacro")

/// The renamed form: `@RawOperation("get-task")` when the method name is not the operationId.
@attached(peer)
public macro RawOperation(_ operationID: String) =
    #externalMacro(module: "WireOpenAPIMacros", type: "OpenAPIControllerMacro")

/// Marks a **typed** operation handler — one taking the operation's parameters as ordinary Swift
/// arguments and returning its response body — and declares which operation it implements.
///
/// Where `@RawOperation` hands the method the generated `Operations.X.Input` and takes back its `Output`,
/// this generates the decomposition: parameters are bound from `input.path` / `input.query` /
/// `input.headers` and the return value is wrapped in the operation's response. The two coexist per
/// method, so a controller can migrate one operation at a time and keep `@RawOperation` for the ones the
/// annotation set cannot express.
///
/// Parameters are bound with the **same** `@Path` / `@Query` / `@Header` wrappers a WireMVC `@Get` route
/// uses — the same types, not a parallel set — which is the whole point of the unification: one binding
/// vocabulary whether a route came from a document or from an annotation.
///
/// Bare, the method's own name is the operationId.
@attached(peer)
public macro Operation() =
    #externalMacro(module: "WireOpenAPIMacros", type: "OpenAPIControllerMacro")

/// The renamed form: `@Operation("get-task")` when the method name is not the operationId — which is
/// also the case that needs it, since the generated requirement is named by the safe-name transform and
/// `get-task` is not a Swift identifier.
@attached(peer)
public macro Operation(_ operationID: String) =
    #externalMacro(module: "WireOpenAPIMacros", type: "OpenAPIControllerMacro")
