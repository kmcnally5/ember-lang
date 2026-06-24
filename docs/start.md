---
title: Get started
nav_order: 1
description: Install the emberc compiler and run your first Ember program. Ember is a statically-typed systems language — memory-safe without a garbage collector, compiled to C.
---

# Ember

**A statically-typed, brace-delimited systems language — safe without a garbage collector.**

Ember is in the lineage of C, C#, and Rust: ownership with move/borrow checking and deterministic
reference counting (no GC, no pauses, no reference cycles), a real type system with generics and
exhaustive pattern matching, structured concurrency, and verification built into the language. The
reference compiler is written in C with no third-party dependencies.

> Status: **active development** (pre-1.0). The language and compiler evolve together.

## Read

- [Home](/) — the landing page.
- [Language reference](/language) — what runs today.
- [The Ember Book](/guide/) — the long-form guided tour.
- [For LLMs](/for-llms) — the priors cheat-sheet; paste it into a model before asking it to write Ember.
- [Flare](/flare) — the declarative UI layer.
- [Architecture](/architecture) — compiler & toolchain decisions.
- [Manifesto](https://github.com/kmcnally5/ember-lang/blob/main/MANIFESTO.md) — the design philosophy and the decisions behind the language.

## Get it

The source, build instructions, and examples are on GitHub:
**[github.com/kmcnally5/ember-lang](https://github.com/kmcnally5/ember-lang)**

```sh
git clone https://github.com/kmcnally5/ember-lang
cd ember-lang
make            # builds the compiler
make test       # runs the test suite
make install    # installs to ~/.ember
```

```ember
fn main() -> int {
    println("Hello, Ember!")
    return 0
}
```

Ember is released under the [MIT License](https://github.com/kmcnally5/ember-lang/blob/main/LICENSE).
