# Ember — VS Code extension (source)

This directory is the **canonical source** for the Ember VS Code extension. It is small,
intentional editor *glue* — the actual language intelligence lives in the compiler
(`emberc --lsp`, in `src/lsp.c`), not here.

| File | Role |
|------|------|
| `extension.js` | Thin launcher: starts `emberc --lsp` over stdio and brokers JSON-RPC via `vscode-languageclient`. |
| `package.json` | Manifest: declares the `ember` language (`.em`), the TextMate grammar, and the `emberLsp.*` settings. |
| `language-configuration.json` | Brackets, comments (`//`), auto-closing/surrounding pairs. |
| `syntaxes/ember.tmLanguage.json` | TextMate grammar — **syntax highlighting** (keywords, types, strings + interpolation, contracts, builtins, numbers, operators). **Generated — do not edit by hand** (see below). |

## Two independent mechanisms

- **Syntax highlighting** comes purely from the TextMate grammar above. It works with no
  server running and colours `.em` files offline.
- **Diagnostics / hover / go-to-definition / completion / document symbols** come from the
  LSP (`emberc --lsp`). Coloring and the LSP are separate — one can work while the other
  doesn't.

## Stuck? Run the doctor first

```
make doctor        # or: emberc --doctor — checks emberc, the stdlib, and the shared frontend
```
It prints `[ok]`/`[!!]` for each piece of the setup with the exact fix. Start here.

## Install / update

VS Code only loads extensions from `~/.vscode/extensions`, so deploy with:

```
make install-vscode
```

then **reload the VS Code window** (Cmd-Shift-P → "Developer: Reload Window"). The deployed
copy is global — it activates for any `.em` file anywhere on the machine.

After changing the grammar, re-run `make install-vscode` and reload.

## The grammar is generated — don't hand-edit it (OFI-033)

The keyword / primitive-type / builtin vocabulary lives in **one** place, `include/vocab.def`,
which the lexer and the LSP also compile from — so highlighting, hover, completion, and the
lexer can never disagree. `syntaxes/ember.tmLanguage.json` is emitted from that table by a
build-time tool (`tools/gen_editor_assets.c`); its structural rules (strings, numbers,
operators, the `fn`-name capture) are authored in that tool, not the JSON.

- To add/change a keyword, builtin, or primitive: edit `include/vocab.def`, then
  `make gen-editor-assets` to reflow the grammar.
- `make test` runs `make check-editor-sync`, which fails the build if the committed grammar is
  stale relative to `vocab.def`. So a forgotten regenerate is caught, not shipped.
