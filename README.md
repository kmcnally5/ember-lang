<p align="center">
  <img src="docs/ember.png" alt="Ember" width="240">
</p>

# Ember

**Ember is a statically-typed, brace-delimited systems programming language** in the lineage of
C, C#, and Rust — designed to be safe without a garbage collector, fast to compile, and unusually
predictable for both humans and language models. The reference compiler is written in C with **no
third-party dependencies**.

> Status: **active development** (pre-1.0). The language and its compiler are evolving together;
> expect sharp edges and breaking changes. See [MANIFESTO.md](MANIFESTO.md) for the design
> philosophy and [docs/language.md](docs/language.md) for the current reference.

Website: **[ember-lang.org](https://ember-lang.org)**

## Why Ember

- **Memory-safe without a GC.** Ownership with move/borrow checking and deterministic
  reference counting — no garbage collector, no pauses, and no reference cycles by construction.
  Mutable aggregates are uniquely owned; shared values are immutable. When you genuinely need
  shared or graph-shaped data, Ember provides blessed tools: `rc struct` (shared immutable structs)
  and `std/slotmap` (a generational arena).
- **A real type system.** Generics with bounds, enums with exhaustive pattern matching,
  `Option`/`Result` with `?`, interfaces with both static and dynamic dispatch, and zero-cost
  **newtypes** (`type UserId = int`) with **refinement types**
  (`type Percent = int where 0 <= self && self <= 100`) that turn unit/range mistakes into
  compile-time or construction-time errors.
- **Concurrency that's structured.** `nursery`/`spawn`/typed channels, with an M:N green-thread
  scheduler — data-race-free because the only shared mutable state is an atomic refcount.
- **Verification built in.** Executable `requires`/`ensures` contracts fused with an execution
  "tape", plus a static prover — a closed loop designed for an LLM to debug against.
- **Two backends, one semantics.** A bytecode VM is the canonical reference; an AST→C native
  backend produces standalone binaries. A differential test keeps them bit-for-bit identical.
- **Batteries included where it counts.** UTF-8 strings, array slices, C FFI (`extern "c"`),
  explicit-width numerics, and a standard library written in Ember (`std/string`, `std/list`,
  `std/map`, `std/set`, `std/slotmap`, `std/http`), plus an opt-in immediate-mode graphics stack.
- **First-class editor support.** An in-tree language server (`emberc --lsp`) with hover,
  go-to-definition, completion, find-references/rename, semantic tokens, inlay hints, signature
  help, and prover verdicts — wired up for both VS Code and Zed.

## Build

Ember runs on **macOS and Linux** (x86_64 and arm64). The core build needs only a C17 compiler (Apple clang or gcc) and GNU Make — no other dependencies. On Linux the installer provisions the optional graphics/networking dependencies via your system package manager (apt/dnf/pacman/zypper/apk), building raylib from source where it isn't packaged.

```sh
make            # builds build/emberc
make test       # runs the golden + differential test suite
make install    # installs to ~/.ember (emberc on ~/.ember/bin, stdlib on ~/.ember/std)
```

## Hello, Ember

```ember
fn main() -> int {
    println("Hello, Ember!")
    return 0
}
```

```sh
build/emberc --emit=run hello.em      # run on the VM
build/emberc -o hello hello.em        # compile a native binary
./hello
```

## Documentation

- [MANIFESTO.md](MANIFESTO.md) — the design philosophy and the decisions behind the language.
- [docs/language.md](docs/language.md) — the language reference (what runs today).
- [docs/THE_EMBER_BOOK.md](docs/THE_EMBER_BOOK.md) — the long-form guided tour.
- [docs/architecture.md](docs/architecture.md) — compiler/toolchain engineering decisions.
- [docs/flare.md](docs/flare.md) — Flare, the declarative UI layer over the graphics backend.
- [examples/](examples/) — sample `.em` programs.

## Editor support

Extensions live under [editors/](editors/) — VS Code (`editors/vscode`) and Zed (`editors/zed`).
Both drive the same `emberc --lsp` server. The Zed syntax grammar is published separately as
[tree-sitter-ember](https://github.com/kmcnally5/tree-sitter-ember).

## License

Ember is released under the [MIT License](LICENSE).

The embedded UI font (`src/font_inter.h`) is [Inter](https://github.com/rsms/inter), distributed
under the SIL Open Font License 1.1.
