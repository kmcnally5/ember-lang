# Ember — Zed extension (source)

This directory is the **canonical source** for the Ember [Zed](https://zed.dev) extension. Like the
VS Code one (`editors/vscode/`), it is small, intentional editor *glue* — the language intelligence
lives in the compiler (`emberc --lsp`, in `src/lsp.c`), not here.

| File | Role |
|------|------|
| `src/lib.rs` | The extension (Rust → WebAssembly). Tells Zed how to launch `emberc --lsp`; nothing else. |
| `Cargo.toml` | Pins `zed_extension_api` (0.4.x — the last release targeting `wasm32-wasip1`). |
| `extension.toml` | Manifest: registers the tree-sitter grammar and the language server. |
| `languages/ember/config.toml` | Declares the `Ember` language for `.em`, comments (`//`), brackets. |
| `languages/ember/highlights.scm` | tree-sitter highlight queries — **syntax highlighting**. |
| `tree-sitter-ember/` | The tree-sitter grammar (its own git repo; Zed builds it from `src/parser.c`). |

## Two independent mechanisms

- **Syntax highlighting + outline** come from the tree-sitter grammar (`tree-sitter-ember`) and
  `highlights.scm`. The grammar is **lexical-depth only** — it tokenizes; it does not re-parse
  Ember's semantics. (A full grammar would be a second parser of Ember syntax, the "two frontends"
  trap; the C compiler stays the one frontend — see `docs/architecture.md`.)
- **Diagnostics / hover / go-to-definition / completion / document symbols** come from the LSP
  (`emberc --lsp`). The two are separate — one can work while the other doesn't.

## Prerequisites

1. **emberc installed** — `make install` (deploys `~/.ember/bin/emberc`). `src/lib.rs` looks for
   `emberc` on the worktree PATH first, then falls back to `~/.ember/bin/emberc`.
2. **Rust via `rustup`, NOT Homebrew.** Zed compiles the extension to wasm itself and drives the
   build through rustup. With brew's `rust` it cannot add the wasm target and the build fails. Set up:
   ```
   brew uninstall rust                                   # avoid a two-cargo PATH conflict
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   rustup target add wasm32-wasip1
   ```
   This toolchain is needed only to *build the Zed extension* — `emberc` itself stays dependency-free.

## Stuck? Run the doctor first

```
make doctor        # checks emberc, the stdlib, the frontend, AND the Rust+wasm toolchain Zed needs
```
It prints `[ok]`/`[!!]` for each piece with the exact fix — start here before debugging anything.

## Install / update

```
make build-zed     # cargo build --release --target wasm32-wasip1 (sanity-build the wasm module)
```
then in Zed: command palette → **`zed: install dev extension`** → select this `editors/zed/`
directory. Zed compiles the wasm module and the grammar and activates them for any `.em` file.

After changing `src/lib.rs`, `config.toml`, or `highlights.scm`, rebuild the dev extension from the
same menu (or `make build-zed` then reinstall).

## The grammar is a local git repo (dev) — regenerate after editing it

Zed loads a tree-sitter grammar from a git `repository` + `rev`. For development, `extension.toml`
points `repository` at `tree-sitter-ember/` via a `file://` URL and pins `rev` to a commit SHA. The
generated `src/parser.c` is committed (Zed compiles that — it does not run `tree-sitter generate`).

After editing `tree-sitter-ember/grammar.js`:
```
cd tree-sitter-ember
npx tree-sitter-cli generate          # regenerate src/parser.c
git add -A && git commit -m "..."     # new commit
git rev-parse HEAD                     # copy this SHA...
```
…then update `rev` in `extension.toml` to the new SHA and reinstall the dev extension.

To **publish** the extension later, push `tree-sitter-ember` to a hosted git remote and replace the
`file://` `repository` with that URL.

## Keeping highlight vocabulary in sync (planned)

The keyword / type / builtin lists in `tree-sitter-ember/grammar.js` mirror `include/vocab.def` —
the single source of truth the lexer and LSP also compile from. Auto-emitting `highlights.scm`'s
keyword lists from `vocab.def` (extending `tools/gen_editor_assets.c`, the way the VS Code TextMate
grammar already is) is the planned next step so a vocabulary change can't drift the Zed colours.
