import SwiftSyntax
import SwiftSyntaxMacros

/// `@OpenAPIController` is a **marker**. It generates nothing; the build plugin reads the attribute (and
/// its `spec:` argument) to collate the controller onto the aggregate proxy, and `WireOpenAPIGen` emits
/// that proxy's `RouteContributor` conformance.
///
/// It used to expand to a per-controller transport conformance. That cannot survive aggregation:
/// with one conformer per spec the witness belongs to the proxy, not to any single controller — and it
/// could not be emitted from generated code anyway, since `RouteContributor` refines `Sendable` and
/// Swift requires a `Sendable` conformance in the type's own file.
public struct OpenAPIControllerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}
