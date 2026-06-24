---
title: "Colophon"
parent: "Guide"
nav_order: 8
---

# Colophon

This book describes the Ember language as it stood in **mid-June 2026**, early in its life and
moving fast. This edition was refreshed as several features landed in quick succession —
**dynamic dispatch** (interfaces as value types), the **bitwise and shift operators** plus the
explicit **wrapping-arithmetic** builtins, the **generic-keyed `Map<K, V>`** and the bounded
generic structs underneath it, the **pointer/buffer/handle FFI**, and — largest of all — the
**native C backend** that compiles a whole program to a standalone binary
([Chapter 22](/guide/ch-22)) — each of which had been
"not yet" only a day or two earlier. It
covers only what had been built and tested by the time of writing; the
[Not Yet List](/guide/ch-23) marks the boundary. A later pass — this one — folded
in what had landed since: **array slices** and explicit **`.clone()`**, the non-blocking
**`try_recv`**, **struct keys** for `Map`/`Set`, a returned C **`char*` arriving as a copied-in
`string`** (how `std/http` brings a response body home), and — the largest piece — **Flare's
animation** (springs + FLIP), its **modal/popover overlays**, and a much wider **widget catalogue**.

Every Ember snippet in these pages was compiled and run with the reference compiler before being
written down, and the outputs shown are the outputs produced. Where this book and the language's
formal specification disagreed, the book follows **what the compiler actually does** — and
refreshing it turned up a few places where the spec's prose had drifted behind its own
implementation (a sentence still calling structs "immutable records," another claiming there was
no prelude, a stale note on which generic bounds were allowed — and, this pass, a `Map` key still
said to need `Copy` and Flare's inline Markdown still described as unrendered). Those were noted and filed as
Opportunities For Improvement rather than copied, which is exactly the bargain this book makes
with itself.

Ember will have grown since you read this. Treat the *spirit* — safe by default, simple by
default, fast to build, honest about its edges — as the durable part, and check the current
spec and examples for the details. The fire's only just been lit.

*Written by the fireside. Mind the sparks.*
