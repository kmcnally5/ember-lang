---
title: "Colophon"
parent: "Guide"
nav_order: 8
---

# Colophon

This book describes the Ember language as it stood in **late June 2026**, early in its life and
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

A further pass folded in the run of features that landed in late June: **`Show`** (a `fn show(self) ->
string` makes any value interpolate), **named enum construction** (`Circle(radius: 2.0)`), the
**`resource struct`** that lets a value own and auto-close a C handle — and **`std/sqlite`** built on
it — **full-range `u64` literals**, the **`rc struct`** and **`std/slotmap`** sharing tools, and
Flare's **60fps** work (list virtualization, idle-CPU gating) with **enter/exit animation, fades, and
toasts**. The toolchain also grew a **fourth gate** (`ledger`, the resource-linearity fuzzer) and now
builds and runs on **Linux** alongside macOS.

A later pass began Ember's **type-system campaign**: **newtypes** (`type UserId = int`, a distinct
nominal type over a scalar or string, erased to its base at zero cost) and **refinement types**
(`type Percent = int where 0 <= self && self <= 100`, a predicate checked at construction) — both in
[Chapter 7](/guide/ch-07). The run-time **fault** also grew sharper: an unhandled
error now renders its payload as data (`values: error = IoErr { code: 5 }`) at a true `file:line:col`
([Chapter 19](/guide/ch-19)).

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
