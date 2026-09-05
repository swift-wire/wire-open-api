# Writing an OpenAPI controller

What `@OpenAPIController` marks, and what the bare form means that the `spec:` form does not.

## Overview

A controller is a type conforming to a document's generated `APIProtocol`, marked as a graph
binding and as an OpenAPI controller:

```swift
@Singleton
@OpenAPIController
struct TaskController: APIProtocol {
    @Inject var repository: TaskRepository
    …
}
```

`@Singleton` is what makes it a binding — the same requirement a WireMVC `@Controller` has.
`@OpenAPIController` is a **marker**: it generates nothing. The plugin reads it and emits a
separate proxy carrying the route-contributor conformance.

The conformance cannot be generated on your type, and the reason is a language rule worth
knowing: `RouteContributor` refines `Sendable`, and Swift requires a `Sendable` conformance to be
declared in the type's own file. So it goes on the plugin-emitted proxy instead.

## There is no base path

Unlike `@Controller("/todos")`, this attribute takes no path. The prefix operations register under
belongs to the document's `servers:` block, applied by the runtime's own
`apiPathComponentsWithServerPrefix`.

With controllers aggregated per document, a per-controller path would also be ambiguous the moment
two of them disagreed — so there is nowhere sensible to put one.

## The two forms

**Bare `@OpenAPIController`** means *the document beside this controller* — the one in the module
the controller is declared in.

**`@OpenAPIController(spec: "TaskAPI")`** names the module owning the generated `APIProtocol`.
Controllers sharing that value land on one proxy, and each distinct value gets its own.

"Beside this controller" rather than "in the target being compiled" is a deliberate choice. The
two coincide for an app generating its own document, and diverge the moment a spec and its
controllers ship together in a library — which is the ordinary way to serve one document from
several runtimes. Resolving against the compiling target would make the bare form mean something
the author cannot see from the file they are reading, since the answer would depend on which
executable happened to pull the library in.

The `spec:` value stays a use-site argument for the same reason: a document's generated types and
the controllers implementing them genuinely can live in different modules. Where a controller is
declared therefore *narrows* which document it implements without settling it.

A `spec:` naming no such dependency is an **error**. It is never taken as a label and quietly
resolved against some other document — that would compile against the wrong one and report itself
as a missing operation for operations nobody wrote.
