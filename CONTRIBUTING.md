# Contributing

**The contribution policy — what may go straight to a pull request, what needs a proposal first, and
where AI assistance sits — is the family-wide one at
[swift-wire/.github](https://github.com/swift-wire/.github/blob/main/CONTRIBUTING.md).** Read that
first.

This file covers what is specific to building and testing *this* package. It exists separately
because GitHub serves a repository's own `CONTRIBUTING.md` instead of the organisation default, not
because the policy differs here.

## Building and testing

Two packages, and both need running:

```sh
swift test                   # the core: codegen, macros, naming, validation
cd Fixtures && swift test    # the runnable example and its integration suite
```

`Fixtures/` is a separate package with a path dependency on the root. It is where
`WireOpenAPIBuildPlugin` actually runs, so a change to the plugin or to what the codegen emits is
unverified until the fixtures build.

Both packages are tools-version 6.4 and need the toolchain pinned in `.swift-version`. CI installs
exactly that one.

There are two golden tools guarding generated output — run them the way CI does:

```sh
swift run NamingGoldenTool --check
swift run DiagnosticGoldenTool --check
```

A diff from either is not automatically a bug; it is an unintended change until someone re-records
it deliberately.

## Documentation

User-facing documentation is the DocC catalog at `Sources/WireOpenAPI/WireOpenAPI.docc`. Build it
the way CI does:

```sh
swift package generate-documentation --target WireOpenAPI --diagnostics-file /tmp/docc.json
python3 Scripts/docc-gate.py /tmp/docc.json
```

The gate is the point of it: the articles reference symbols by name, so a renamed or removed macro
breaks a link rather than a build — silently, and only for a reader. A doc comment naming a symbol
that no longer exists fails the same way.

It is two commands rather than `--warnings-as-errors` because a `public import` can carry a
dependency's symbols into this module's graph, and DocC then reports unresolved links in doc
comments this package does not own. The script filters the structured diagnostics down to files in
this repository.

> **Check `Package.resolved` before committing.** A documentation build resolves the graph with
> every trait enabled, which can pin packages a plain `swift package resolve` prunes. Commit the
> resolve's output, not the one a docs build left behind.

Design notes under `Documentation/Notes/` are a different thing: they record *why* a design is what
it is, and are not part of the published documentation.
