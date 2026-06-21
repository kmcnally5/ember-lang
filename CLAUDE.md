# CLAUDE.md — Project Ember

## Ember coding rules
- I like to see 5 line spaces between every function/method in a code file
- No stubs, no functionless code - we are building a language here and there is no room for this here!
- OFI - "Opportunity for Improvement" - if you are working on something and find a bug, design flaw, inconsistency 
with our manifesto etc... Dont ignore or code round it - raise this as an OFI and number it accordingly.  Keep an OFI
log for the Ember project to track opened and closed items.
- Please do not write tests that will be used only once or twice in this Ember project folder - write these
to /tmp instead.  This project folder is for the language, it's stdlib and it's code examples only.
- If you need anything or more information feel free to search the web for the information you need.  I have no problem
with you searching the web for resources that benefit the language directly.
- After any new logic is implemented an appropriate test needs writing and putting into the tests/ folder.  This can
then be used by both of us as a means of regression checking etc...
Guidance for Claude Code when working in this repository.
- The core language documentation must be kept up to date in docs/ after any implementation or code changes.
- When you hit a bug - reach for the tape tool and a dogfood app to prove/find it first!  Always!
## What Ember is

Ember is a new, statically-typed, **brace-delimited** systems programming language (in the
lineage of C, C#, kLEX/FROG). It is in **active development** as of June 2026. The language
itself is the product; the reference compiler is being **implemented in C** (Apple clang 17,
arm64) for speed, portability, zero install-time dependencies, and total control over memory
layout and runtime.

Two distinct things — don't conflate them:
- **The Ember language** — what we are designing. Influenced by Rust, Zig, Go, and C, but
  not bound by any of them. See [MANIFESTO.md](MANIFESTO.md) for the design philosophy and
  the explicit list of things we are improving on relative to Rust.
- **The Ember compiler** — written in C. Lexer → parser → AST → type checker → codegen.
  Engineering decisions about the compiler, toolchain, and repo (as opposed to the language)
  are recorded in [docs/architecture.md](docs/architecture.md) — the counterpart to the manifesto.
  Consult and extend it when a choice is about *how the compiler is built*, not *what the language is*.

## Toolchain (verified available on this machine)

- `clang` 17.0.0 (Apple), also aliased as `gcc` and `cc` — arm64-apple-darwin
- GNU Make 3.81
- No git repository yet. Ask before `git init`.

## Working agreement

- **Discuss design before implementing.** Ember is a language; a syntax or semantics choice
  is expensive to reverse once there's a parser and test corpus around it. When a task touches
  language design, propose and confirm before writing code.
- **Every language-design decision must trace to the manifesto.** If a choice contradicts
  [MANIFESTO.md](MANIFESTO.md), either don't make it or update the manifesto deliberately and
  say so.
- **C style:** C17, compiled with `-Wall -Wextra -Werror -std=c17`. No undefined behavior.
  Prefer arena/region allocators over scattered `malloc`/`free`; the compiler is a
  batch process, so bump-allocate and free regions wholesale.
- **No third-party C dependencies** without explicit sign-off. Part of the point of C here is
  the empty dependency tree. The standard library + what we write is the baseline.
- **Test as we go.** Every language feature lands with example `.em` programs that must
  compile and run. A feature without a test that exercises it is not done.
- **Don't commit, push, or `git init`** unless asked.

## Layout (intended — build out as we go)

```
ember/
  CLAUDE.md        — this file
  MANIFESTO.md     — language design philosophy and the "improve on Rust" decisions
  docs/            — language spec (language.md, grammar.ebnf) + architecture.md (compiler/toolchain decisions)
  OFI.md           — dated log of bugs/flaws/improvements found while building
  src/             — compiler source (C)
  include/         — headers + vocab.def (single source of truth for the lexical vocabulary)
  tools/           — build-time developer tools (not shipped in emberc), e.g. the editor-asset generator
  examples/        — .em sample programs (double as tests)
  Makefile         — `make` builds the compiler; `make test` runs examples
```

## Conventions

- Ember source files use the `.em` extension.
- When unsure about a language-design tradeoff, present a recommendation with reasoning rather
  than an exhaustive menu — but get a decision before baking it into the grammar.
