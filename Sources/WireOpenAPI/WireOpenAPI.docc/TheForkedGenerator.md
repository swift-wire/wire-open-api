# The forked generator

Why WireOpenAPI needs a fork today, what the two changes are, and what the alternative cost.

## Overview

Operations are dispatched by calling the generated per-operation method on a `UniversalServer`
built for the request. That is the only place an operation's deserializer and serializer exist, so
dispatching *one* operation — rather than registering a whole document — requires reaching it.

Stock swift-openapi-generator makes that impossible. The
[fork](https://github.com/tachyonics/swift-openapi-generator/tree/swift-wire) carries two small
changes:

- the `UniversalServer` extension is no longer `fileprivate`, so other generated code in the same
  module can call it;
- its methods follow the configured `accessModifier:` rather than being internal regardless — as
  `registerHandlers` in the same file already does — which is what a document in its own module
  needs, since its caller is in another module.

Because those methods extend `UniversalServer`, which is `@_spi(Generated)`, they stay SPI however
publicly they are declared. The emitted file imports a spec module the same way.

## The alternative, and why it is not on main

Keeping one registration and reaching the request's subject through a task-local works on a stock
generator, so it is the obvious thing to want.

It was measured: equal at p50, and **worse in mean and p99**. It also costs the whole
collecting-transport machinery. Neither half of that is worth paying to avoid a two-line
patch, so main does not carry it — the branch is kept for the record rather than as a fallback.

## What this means for adopting

This is the constraint to weigh before adopting, and it is not one you can work around at the
call site. Depending on a fork of a code generator is a real cost: it is a pin to maintain and a
divergence to re-check whenever the upstream generator moves.

The changes are small and narrow enough to be plausible upstream, which is the way out — but
until they are taken, a consumer builds against the fork.
