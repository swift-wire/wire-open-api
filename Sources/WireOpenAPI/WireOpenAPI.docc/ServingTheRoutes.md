# Serving the routes

One call, and why there is no WireOpenAPI-specific one.

## Overview

Serving collated operations on Hummingbird, Vapor or Lambda is
`WireMVCServerTransport.apply(graph, to: transport)` — the same call a WireMVC app already makes,
registering every collated route uniformly.

An app using the `@WireMVCBootstrap` composition root makes no call at all: the generated entry
point registers every route contributor, and an operation is one of them.

## Why there is no WireOpenAPI facade

A WireOpenAPI-specific `apply` would have to filter the route collection by conformance to find
"its" routes. Two things follow, and both are bad.

It would **silently drop the app's `@Controller` routes**, because they are not its. And used
alongside the correct call, it would **double-register** every operation, because the correct call
registers the whole collection including these.

The absence is therefore deliberate rather than missing. One collection, one call, and an
operation is a member of that collection like any other route.

## Handlers only

OpenAPI is a transport surface, not a runtime. This adapter carries handlers and nothing else:
services and lifecycle belong to the runtime's own adapter, which knows what a server is and how
to shut one down.

The two coexist on one graph, which is what makes the split workable — an app serves its
OpenAPI operations and its background services from the same composition root, with each concern
owned by the adapter that understands it.

## What an operation inherits

Because the collation key is WireMVC's, an operation gets everything a route gets without this
package implementing any of it:

- the router, the `@NotFound` fallback and the `405` handler
- global, controller-scope and route-scope `@Middleware`
- `@ErrorResponse` tiers at every scope
- request scope, and `@Teardown` at the end of the request
- the coding settings the scope selected

That list is the argument for the shared key. Each item would otherwise have needed a second
implementation here, and the two would have drifted.
