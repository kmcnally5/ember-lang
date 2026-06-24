---
title: "Guide"
nav_order: 2
has_children: true
---

# Ember by Firelight

### A friendly, honest field guide to writing Ember — as it actually stands today

*Covering the language as built and tested in June 2026. Everything in this book was compiled and run before it was written down. Nothing here is aspirational.*

---

> **The one promise this book makes**
>
> Ember is a young language in active design, and it is growing quickly. A book about a
> moving target can lie to you in two directions: by describing features that don't exist
> yet, or by going stale the moment something lands. This book solves the first problem
> ruthlessly — **every single code sample was run through the compiler and produced the
> output shown** — and it makes peace with the second by telling you, at every turn, exactly
> where the edges are. When something is designed but not built, you'll find it in
> [Chapter 23: The "Not Yet" List](/guide/ch-23), clearly fenced off, and
> nowhere else.
>
> If you can read one programming language already — any of them — you can learn to write
> working Ember from this book. That includes you, dear reader, even if your last program
> ended in a stack trace you emailed to a friend.

---

## How to read this book

You don't have to read it cover to cover, but the early chapters genuinely build on each
other, so if you're new, start at the start. Each chapter follows the same rhythm: a plain
explanation, real code you can run, the gotcha that will bite you if nobody warns you, and —
because all work and no play makes for a dull manual — the occasional **Fireside trivia**
box, where we wander off to look at something faintly ridiculous and true.

A few conventions:

- Code you can run looks like this and has been run:

  ```ember
  fn main() -> int {
      println("Hello from Ember")
      return 0
  }
  ```

- When the compiler says something back to you, it looks like this:

  ```
  => 0
  ```

> **Fireside trivia.** Ember's reference compiler is written in C — about a dozen thousand
> lines of it — and has *no third-party dependencies at all* for its default build. It links
> the C standard library and nothing else. The entire toolchain (compiler, language server,
> property fuzzer, contract prover, JSON reader) is written in-tree. The one exception is
> the optional graphics build, which is kept so firmly off the main path that you can build
> and test the whole language on a machine with no display.

---

## Running Ember at all

Ember programs end in `.em`. You compile and run one with the `emberc` compiler:

```
emberc --emit=run hello.em
```

That compiles the program *and* executes it, printing any output, then a final line showing
the value `main` returned:

```
=> 0
```

`--emit=run` is the one you'll use most. The compiler can do a lot of other things to your
program — show you the tokens, the syntax tree, the bytecode, fuzz your contracts, prove
them, replay a run deterministically — and all of those live in
[Chapter 21: The Whole Toolbox](/guide/ch-21). It can also compile your program
to a **standalone native binary**, with no interpreter anywhere in sight — that's
[Chapter 22: Compiling to Native](/guide/ch-22). For now, `--emit=run` is all
you need.

Exit codes, if you script things: `0` success, `64` you used the compiler wrong, `65` your
program has an error (lexing, parsing, type-checking, *or* a runtime fault), `66` the file
couldn't be read.

---

## Building Ember from source

The samples above assume you already have an `emberc`. Producing one is deliberately dull:
Ember's compiler is written in C with **no third-party dependencies**, so on any machine with a
C compiler and `make`, a single command does it.

```
make
```

That builds the everyday compiler at `build/emberc` — a debuggable `-O0 -g` build — together with
the small runtime libraries that native binaries link against. To confirm everything actually
works, run the regression suite, which rebuilds whatever is stale and then runs every example in
this book:

```
make test
```

Those two are ninety per cent of what you'll ever type. Everything else the `Makefile` can do is
below, grouped by why you'd reach for it.

**Building the compiler**

| Target | Produces | Notes |
|--------|----------|-------|
| `make` (`make all`) | `build/emberc` + `libember_rt.a`, `libember_rt_par.a` | The dev build: `-O0 -g`, quick to rebuild and debuggable. The two `.a` files are the runtime `emberc -o` links into native programs. |
| `make release` | `build/emberc-release` | The optimized `-O2` compiler — the one `make install` ships. |
| `make parallel` | `build/emberc-par` | Same language, multicore runtime: `spawn`/`nursery`/channels run on real OS threads ([Chapter 14](/guide/ch-14)). |
| `make graphics` | `build/emberc-gfx` | Links raylib + FreeType. *Needs an external library* (see below). |
| `make net` | `build/emberc-net` | Links libcurl for HTTPS. *Needs an external library.* |
| `make net-graphics` | `build/emberc-net-gfx` | Networking + graphics + threads at once — the build the desktop demo uses. *Needs both libraries.* |

**Finding bugs**

| Target | Produces | Notes |
|--------|----------|-------|
| `make asan` | `build/emberc-asan` | AddressSanitizer build — running a `.em` program flags use-after-free / overflow with a stack trace. |
| `make asan-par` | `build/emberc-asan-par` | The same, exercising the cross-thread (parallel) paths. |
| `make asan-trace` | `build/emberc-trace` | ASan plus the double-drop detector — the "memory tape" of [Chapter 19](/guide/ch-19). |

**Testing, and the three gates**

| Target | What it does |
|--------|--------------|
| `make test` | The regression suite: builds everything, checks the editor grammar is in sync, runs every example. |
| `make test-update` | Regenerate the snapshot goldens. Review the diff before you trust it. |
| `make test-lsp` | Language-server regression (the editor integration). |
| `make test-graphics` | Graphics/UI regression. Needs raylib and a display. |
| `make test-parallel` | Correctness suite for programs that are only correct under the multicore runtime. |
| `make crucible` | The memory-ownership **fuzzer** — generates danger-zone programs and runs each through five oracles ([Chapter 20](/guide/ch-20)). |
| `make ceilings` | The compiler-**limits** stress tester: pushes constants, locals, fields and the rest past the 256 boundary to prove nothing silently wraps. |
| `make opcheck` | *(new)* The bytecode **operand-layer** gate — proves the encoder, decoder, disassembler and VM all agree on every opcode's operand widths, so they can't drift apart. |

**Benchmarks**

| Target | What it does |
|--------|--------------|
| `make bench` | Build the release compiler, then run and time every program in `benchmarks/`. |
| `make parbench` | Run the concurrency suite under both the serial and parallel compilers and tabulate the speedup. |

**Editors, installing, cleaning**

| Target | What it does |
|--------|--------------|
| `make gen-editor-assets` | Regenerate the VS Code syntax grammar from the single source of truth, `include/vocab.def`. |
| `make install` | Build release, then install `emberc` + the standard library to `~/.ember` (override with `PREFIX=`) so editors and tools find it from any folder. |
| `make install-vscode` | Package and install the VS Code extension globally. Needs Node/npm and VS Code. |
| `make clean` | Delete `build/`. |

> **The three gates, and why they exist.** `crucible`, `ceilings` and `opcheck` are siblings, each
> guarding one recurring class of *compiler* bug. Crucible hunts memory-ownership mistakes; ceilings
> hunts narrow operands that wrap past 255; and the newest, **`opcheck`**, hunts operand-layout
> *drift* — the bug where the code that writes an instruction and the code that reads it quietly
> disagree on how many bytes it occupies. It works in two halves: a codec round-trip that encodes and
> decodes every operand kind, and a special `-DEMBER_OPCHECK` build of the VM that, after every
> instruction across the whole test corpus, asserts the handler consumed *exactly* the bytes the
> opcode's spec declared. Run it after touching any opcode.

**A note on dependencies.** `make`, `make test`, all three gates, the sanitizers and the benchmarks
need nothing but a C compiler — that is the whole point of writing the compiler in C. Only three
targets reach outside the standard library: `graphics` (and `test-graphics`) want raylib + FreeType,
found via `pkg-config`; `net` wants libcurl, via `curl-config`; and `net-graphics` wants both.
`make install-vscode` additionally needs Node/npm and VS Code. The default path stays
dependency-free and display-free, so you can build and test the entire language on a headless
machine.
