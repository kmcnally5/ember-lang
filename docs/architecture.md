# Ember — Compiler & Toolchain Architecture

*Engineering decisions for the **compiler and toolchain**. The counterpart to [MANIFESTO.md](../MANIFESTO.md). Started June 2026.*

The manifesto records why the **language** is the way it is. This document records why the
**compiler, toolchain, and repository** are the way they are — the engineering decisions that
future work must respect but that say nothing about Ember-the-language. The project insists on
keeping these two apart (see [CLAUDE.md](../CLAUDE.md): *"don't conflate"* the language and the
compiler); this is where the compiler half lives.

It is a **living** document, not an append-only log: each entry states the rule that is true
**now** and why. For the dated history of what changed and the bugs/flaws found along the way,
see [OFI.md](../OFI.md).

Format: each decision is `## Decision: <short name>` followed by the rule and the reasoning. When
a decision traces to a manifesto section or closes an OFI, it says so.

---

## Decision: the language and the compiler are two separate products

**Rule.** "Ember" names two things that are designed and discussed independently: the *language*
(the product — grammar, semantics, type system) and the *reference compiler* (a batch program
written in C that implements it). A change to one is not automatically a change to the other.

**Why.** A syntax or semantics choice is expensive to reverse once a parser and a test corpus
have grown around it, so language decisions get manifesto-level deliberation. Compiler decisions
(allocation strategy, where a tool lives, how artifacts are generated) are ordinary engineering
and move faster. Conflating them either slows the compiler down with ceremony or sneaks language
design in through the back door. The two "why" documents — manifesto and this file — exist to keep
the line visible.

---

## Decision: `emberc` is user/editor-facing; `tools/` maintains checked-in artifacts

**Rule.** A capability ships **inside `emberc`** only if a user or an editor invokes it: compiling
a program, an `--emit=` analysis *of a program* (`check`, `replay`, `prove`), or serving an editor
(`--lsp`). A capability that only *we* run to maintain something checked into the repo lives as a
standalone program under **`tools/`**, built by the Makefile but never shipped in the compiler.

**Why.** Every `emberc` subcommand should answer a coherent question — "what about *this program*?"
or "serve *this editor*." A generator that dumps static facts about the language itself (e.g. the
editor grammar) answers neither; folding it in as an `--emit` mode would quietly redefine `--emit`
from "transform this program" to "...or also describe the compiler," and would ship build-time-only
developer tooling to every end user. Keeping the boundary makes the compiler's surface honest and
gives a clear home for repo-maintenance tools. First instance: `tools/gen_editor_assets.c` (OFI-033).

---

## Decision: single source of truth + generation, guarded by a build-time sync check

**Rule.** When the same fact must appear in several artifacts, it is authored **once** and the
copies are **derived** — never hand-maintained in parallel. Where the consumers are C, they
`#include` the one table so they *compile* from it and cannot diverge. Where a consumer is not C
(a generated file checked into the repo), a `tools/` generator emits it and a Makefile target
**regenerates-and-diffs in `make test`**, failing the build if the committed copy is stale.

**Why.** Duplicated facts drift; a human "remember to update all four places" is a standing tax and
an eventual bug. A generator that nobody is *forced* to run drifts just as badly — so the value is
in the **enforced diff**, not merely in having a generator. First instance: the lexical vocabulary
(keywords, builtins, primitives) lived in four hand-copied places; it now lives in
[`include/vocab.def`](../include/vocab.def) (X-macros), `#include`d by the lexer and the LSP, with
the TextMate grammar generated from it and gated by `make check-editor-sync` (OFI-033).

---

## Decision: the language server is C, in-tree, sharing the compiler frontend

**Rule.** The LSP is `emberc --lsp` — the same binary, the same lexer/parser/checker, in the same
codebase. It is **not** a separate process in another language re-implementing the frontend.

**Why.** Researched directly (C vs Go) before committing. rust-analyzer is the cautionary tale:
being a separate effort from rustc it had to reimplement the whole frontend, which the Rust team
itself calls an unsustainable maintenance burden. Every LSP that stayed healthy shares its
compiler's frontend (clangd↔Clang, gopls↔go/*, tsserver *is* the compiler). So **the LSP's
language follows the compiler's language** — Ember's compiler is C, therefore the LSP is C. A
separate Go binary would also break the empty-dependency-tree and single-binary promises below.
Ember's frontend already had the expensive prerequisites: an error-tolerant parser and structured
JSON diagnostics built for the LLM loop.

---

## Decision: no third-party C dependencies — everything in-tree

**Rule.** The compiler links libc and what we write, nothing else. New third-party C libraries
require explicit sign-off. Capabilities that another project would pull from a package are written
in-tree instead: the JSON reader/writer (`src/json.c`), the contract prover's Fourier–Motzkin core
(`src/prove.c`), the FFI registry (`src/cextern.c`), the embedded font, the property fuzzer.

**Why.** An empty dependency tree is part of the point of choosing C here. It buys zero install-time
dependencies, total control over memory layout and the runtime, a single self-contained binary, and
no supply chain to audit. The standard library plus what we write is the baseline. The one opt-in
exception is the graphics build (raylib via pkg-config, `make graphics`), kept strictly off the
default path so `make` / `make test` stay dependency-free and display-free. (Manifesto §5g/§5h.)

---

## Decision: arena/region allocation, not scattered malloc/free

**Rule.** The compiler bump-allocates into arenas and frees whole regions at once; it does not pair
individual `malloc`/`free` calls across the codebase. AST nodes and other per-compilation data live
in arenas tied to the compilation's lifetime.

**Why.** The compiler is a batch process: it runs, produces output, and exits. Region allocation
matches that lifecycle, eliminates a class of use-after-free/leak bugs, and is faster than
general-purpose allocation. Gotcha worth knowing: arena nodes are **not** zeroed, so every per-kind
field must be initialised at its creation site (see OFI-026). C is C17, `-Wall -Wextra -Werror
-std=c17`, no undefined behavior.

---

## Decision: a self-contained toolchain directory, with binary-relative stdlib resolution

**Rule.** `make install` deploys a self-contained toolchain to `~/.ember/` (`bin/emberc` + `std/`).
`emberc` resolves the standard library relative to its **own binary** (`<bin>/../std`), falling back
to `$EMBER_STD`, so it finds the stdlib from any working directory with no environment setup. The
VS Code extension's canonical source lives in `editors/vscode/` and deploys via `make
install-vscode`.

**Why.** The stdlib must be locatable no matter where the user runs the compiler, without sudo, env
vars, or a global install — namespaced and user-owned like `~/.cargo`. Binary-relative resolution
makes the toolchain relocatable as a unit. (Editor-extension install mechanics and the
highlighting-vs-LSP split are documented in `editors/vscode/README.md`.)

---

## Decision: one editor-agnostic server, thin per-editor glue under `editors/<editor>/`

**Rule.** `emberc --lsp` is a pure, editor-agnostic JSON-RPC server — no client-specific code. Each
editor gets a *thin glue package* under `editors/<editor>/` whose only jobs are (1) launch
`emberc --lsp` and (2) supply that editor's syntax-highlighting asset in its native format. VS Code
(`editors/vscode/`) is a JS launcher + a **TextMate** grammar generated from `vocab.def`. Zed
(`editors/zed/`) is a Rust→wasm extension implementing `zed::Extension::language_server_command` +
a **tree-sitter** grammar (`tree-sitter-ember`) and `highlights.scm`. Adding editor #3/#4 means a new
`editors/<editor>/` package, not server changes.

**Why.** The intelligence lives once, in the shared frontend (see "the language server is C"); only
the glue is per-editor, so the cost of a new editor is bounded and the server can't drift between
them. Zed forces two hard differences from VS Code — extensions are **Rust→wasm**, and highlighting
is **tree-sitter**, not TextMate — so the TextMate grammar does not carry over. We keep the
tree-sitter grammar **lexical-depth only** (comments, strings, numbers, keyword/type/builtin token
lists, declaration heads): a full grammar would be a *second parser* of Ember syntax, exactly the
two-frontends trap the LSP decision avoids. Semantic features come from `emberc --lsp`; the grammar
just colours. (Generating `highlights.scm`'s keyword lists from `vocab.def`, and a "porting to a new
editor" guide, are the planned next step — the single-source-of-truth net that already guards the
TextMate grammar, extended to tree-sitter.) Building the Zed extension needs Rust via **rustup**
(not Homebrew — Zed drives `rustup target add wasm32-wasip1` itself); like `vsce`/`npm` for VS Code,
it is an opt-in *extension-build* dependency only — `emberc` stays dependency-free.

---

## Decision: the LSP negotiates `positionEncoding` (utf-8 preferred, utf-16 fallback)

**Rule.** The compiler tracks columns in **bytes** throughout (`Token.col`/`length`). The LSP base
protocol defaults the position `character` unit to **UTF-16** code units, so on `initialize` the
server reads `capabilities.general.positionEncodings` (LSP 3.17) and advertises `"utf-8"` (our native
byte offsets — zero conversion) when the client offers it, otherwise falls back to `"utf-16"` and
translates byte↔UTF-16 columns at the wire (`src/lsp.c`, `byte_to_char`/`char_to_byte`). The walk
runs only when utf-16 was negotiated *and* a line carries a byte ≥ 0x80; ASCII and the utf-8 path are
identity.

**Why.** Without negotiation a byte column is silently mis-read as a UTF-16 column by any utf-16
client, so a single non-ASCII byte in a comment or string shifts every diagnostic/hover/jump on that
line (OFI-075). Negotiating utf-8 makes the common case (Zed and VS Code both offer it) exact and
free; the utf-16 fallback makes the server correct for *any* standards-compliant client rather than
"correct as long as the file is ASCII." Lines are encoding-independent and never converted.

---

## Decision: semantic tokens cover the RESOLUTION layer; the grammar covers the LEXICAL layer

**Rule.** Syntax highlighting is split by what each side can know. The editor grammar (tree-sitter
for Zed, TextMate for VS Code) colours the **lexical** layer — keywords, strings, numbers, comments,
operators — from the surface text alone. The LSP's `semanticTokens` provider colours the
**resolution** layer — each identifier re-coloured by what the *checker* resolved it to (type vs
parameter vs property vs enum-variant vs function vs method vs module). It is driven straight off the
semantic index (`src/lsp.c` `handle_semantic_tokens`): every recorded entry's `SemKind` maps to a
legend index, positions go through the same `byte_to_char` encoding translation as everything else,
and the result is the delta-encoded stream LSP requires. The legend in `handle_semantic_tokens` must
stay in lock-step with the one advertised in `initialize`.

**Why.** A grammar cannot tell a type from a variable from a parameter — that needs resolution, which
only the checker has. Splitting the work this way means neither side guesses at the other's job: the
grammar never pretends to resolve (Zed's grammar is deliberately minimal — see the editor-glue
decision), and the LSP never re-lexes. It also makes the minimal-grammar choice pay off twice — the
semantic layer is where the real colour fidelity comes from, and it lights up VS Code and Zed
identically from one implementation. Globals the grammar already handles unambiguously (e.g. builtin
calls) are left to it; the index focuses on resolution-dependent identifiers.

---

## Decision: a symbol's identity for references/rename is (def-file, def-line, spelling)

**Rule.** Find-references and rename are one query over the semantic index: every recorded reference
already carries the file+position of its *definition*, so all references to a symbol are the
occurrences sharing one definition. The identity key is **(canonical def-file, def-line, the
identifier's spelling)** — deliberately **not** def-column. The checker records a coarse def-column
(usually the line start: good enough for "jump to the line", but it collides distinct symbols
declared on one line — a function, its parameter, and an import alias all landed at `1:1`). The
spelling disambiguates them: every reference is an identifier whose text we read back from the
source and compare. Rename is that occurrence set turned into a `WorkspaceEdit`; the declaration is
located by a whole-word search on its definition line (so a coarse def-column never edits the wrong
span), and an invalid new name is refused. All paths are canonicalised (`realpath`) before
comparison and emission, so a file reached two ways (e.g. a `/tmp`→`/private/tmp` symlink) is one
edit group, not two. (`src/lsp.c`: `collect_references` / `cursor_anchor`; `SemEntry.ref_file`
records which file each occurrence lives in.)

**Why.** Scope is **project-wide** — a rename that updated the declaration and same-file uses but
missed a caller in another module would silently break the build, so correctness demands the whole
workspace, not just the open file (Karl's call). Keying on def-column would have been precise in
theory but is unreliable in practice; keying on (def-file, def-line) plus the spelling is robust
against the coarse column and still scope-correct (two same-named locals in different functions have
different def-lines, so they never conflate). The cost is re-indexing each workspace `.em` file per
request (the server walks the root captured at `initialize`, skipping `.git`/`target`/`node_modules`,
and reads unsaved buffers from the open-document store); fine at the current corpus size, with a
project-index cache the obvious later refinement — the same "caching is deferred" note as hover and
diagnostics. Known edges: a symbol referenced only from a file that is *not* under the walked root is
missed, and unsaved edits in an imported file (read from disk during indexing) are not yet reflected.

---

## Decision: inlay hints and signature help find their context LEXICALLY, then read the index

**Rule.** Both features locate *where* the cursor is from the **token stream**, then read *what* to
show from the semantic index / AST. Inlay hints: an unannotated binding is exactly the token pattern
`let`/`var` · IDENT · `=` (annotated has `:` there); the inferred type comes from one of the
binding's uses in the index (`inferred_type_for`), placed right after the name. Signature help: scan
left from the cursor tracking bracket depth to the enclosing `(`, the token before it is the callee,
and the top-level commas between are the active-parameter index; a free function renders per-parameter
labels (so the client highlights the active one), a builtin shows its vocab signature, a method shows
the index's rendered `detail`. (`src/lsp.c`: `handle_inlay_hint`, `handle_signature_help`.)

**Why.** These features fire *while the user is typing*, when the code often doesn't fully parse —
so the *context* (which binding, which call, which argument) must come from tokens, which the lexer
always produces, not from a clean AST. The *content* (the inferred type, the signature) still comes
from the one frontend, so there is no second analysis. The token-pattern test for "unannotated
binding" and the depth-aware comma scan are both robust to surrounding errors. Known limits: an inlay
hint needs at least one *use* of the binding (an unused `let` has no recorded type — same gap as
hovering a binding); signature help highlights individual parameters only for free functions (methods
and builtins show the signature without per-parameter ranges).

---

## Decision: the checker knows graphics SIGNATURES in every build; only the implementation is gated

**Rule.** The graphics primitives' type information — the `NATIVE_GFX_*` ids (`include/builtin.h`),
the name→id resolution (`src/builtin.c`), and the arity/type validation (`src/check.c`) — compiles
into **every** build. Only the *implementation* (the raylib backend, and the VM / native-backend
dispatch that calls it) stays behind `#if EMBER_GRAPHICS`. So the dependency-free default build's
type-checker fully understands a graphics program; it just can't *run* one (the VM no-ops an
unrecognised native id — `make graphics` for a runnable build). Complementing this, the language
server's diagnostic path is **check-only** (`check_diagnostics`: load + type-check, no codegen): an
LSP reports semantic errors, not lowering results, and check-only never touches the gated backend.

**Why.** The signatures are pure data (`draw_rect` = 5 ints) with zero raylib dependency, so gating
them bought nothing and cost correctness: the installed LSP is the default build, so opening any file
that imports `std/ui`/`std/draw` flagged every graphics call as "undefined function" and cascaded
through the whole file (OFI-078: 182 false diagnostics on `examples/11_menus.em`, vs 0 from a graphics
build). Decoupling "the language knows these functions" from "this build links raylib" makes one
dependency-free binary serve the editor correctly for all programs. The check-only LSP path is the
right LSP semantics anyway and sidesteps the question of lowering a graphics call in a non-graphics
build. (Diagnostics are also now attributed to the module being checked, not the entry file — OFI-079 —
so an imported module's errors never leak onto the importer.)

---

## Decision: the LSP surfaces the verification loop — prover verdicts inline + contract code actions

**Rule.** The static contract prover (`src/prove.c`, §5j brick 4) is exposed as **data**, not just a
report: `prove_fn_verdicts(fn, out_proved[])` runs the exact proof `--emit=prove` runs but fills a
verdict array instead of printing (the printing path now wraps it, so the `--emit=prove` output is
byte-identical). The language server drives that to realize the verification-loop differentiator two
ways: (1) **inlay hints** mark each `ensures` clause `✓ proved` (the prover discharged it for all
inputs) or `○ runtime-checked` (outside the linear fragment, or not provable) — the proof shown
*inline* where the contract is; (2) **code actions** (`textDocument/codeAction`) scaffold a `requires`
precondition or an `ensures` postcondition, inserted just before the body brace (contracts parse
order-free, so the position is simple). (`src/lsp.c`: `handle_inlay_hint`'s verdict block,
`handle_code_action`.)

**Why.** This is the post-parity differentiator named earlier in this doc — "the prover can discharge
this line" / "add a `requires`" — that no other young language's LSP offers, and it ties the editor
directly to Ember's north-star verification story (MANIFESTO §5j). It reuses the **one** prover (no
second analysis — the same discipline as the shared frontend), and it makes a normally-invisible
property loud: a model or a human editing a function *sees* immediately whether its spec is machine-
proved. Verdicts ride the inlay-hint channel (subtle, non-cluttering — not a Problems-panel entry for
something that's fine); authoring rides code actions. Scope today: free functions in the prover's
linear-integer fragment; the inlay is honest about everything else (`runtime-checked`).

---

## Decision: `emberc --doctor` — a one-command setup health-check (onboarding is make-or-break)

**Rule.** `emberc --doctor` verifies the pieces a working language server needs and prints a
`[ok]`/`[!!]` line per check with the *exact* fix for anything wrong: the binary in use, that the
standard library resolves (`<g_std_dir>/string.em` opens), and that the shared frontend is healthy
(it type-checks a trivial program in-process via `check_diagnostics`), and — the staleness check —
whether the INSTALLED binary the editor's LSP actually runs (`~/.ember/bin/emberc`) matches this build
(it `popen`s the installed `--version` and compares to `EMBER_VERSION`; mismatched = "rebuilt but not
re-installed", the cause of phantom stale-LSP behaviour). It ends with the editor next-steps.
`make doctor` runs it and adds two repo-side checks: the Rust + `wasm32-wasip1` toolchain the Zed
build needs (distinguishing rustup-present-but-missing-target, Homebrew-`cargo`-but-no-rustup — the
trap that won't build Zed extensions — and no-Rust), and **Zed grammar freshness** (the `tree-sitter-
ember` git HEAD vs the `rev` pinned in `extension.toml`, catching an edited-but-not-bumped grammar).
`make test` runs a regression (`tests/run-doctor.sh`): healthy → exit 0 + all-clear; broken stdlib →
the fix + non-zero exit; `--version`/`--help` consistent.

**Why.** The LSP setup/install phase is where newcomers abandon a young language — one unexplained
failure and the tab closes for good. Every failure we hit bringing the LSP up (stdlib not found, the
rustup-vs-Homebrew trap, a stale installed binary, graphics squiggles) is a "give up" moment for
someone with less context. A doctor turns "something's broken and I don't know what" into "here's the
one thing to fix," which is the highest-leverage anti-friction investment for adoption. It is a
user/editor-facing mode, so it belongs in `emberc` (not `tools/`) per the `emberc`-vs-`tools` rule.

---

## Decision: one version constant; `emberc --help` is the binary's CLI, `make help` is the build menu

**Rule.** `include/version.h` defines a single `EMBER_VERSION` — bump that one line per build and it
flows to `emberc --version`, the `--help` header, the language server's `serverInfo.version` (what
editors display), and `--doctor`'s staleness comparison. `emberc --help` documents only the *binary's*
CLI (the `--emit` modes, `-o`, `--lsp`, `--doctor`, flags); it does **not** list Makefile targets,
because the shipped binary stands alone from the repo. The repo's build/test/install commands live in
**`make help`** instead, and `emberc --help` ends by pointing there.

**Why.** A single constant means the version can never drift between the CLI, the editor's status bar,
and the staleness check (the regression asserts `--version` and `--help` agree). Keeping `emberc
--help` to the binary's own surface respects that an installed `emberc` has no Makefile beside it —
conflating "use the language" with "build the compiler" would mislead a user who installed the
toolchain. `make help` gives the maintainer the one canonical list of build commands so none get lost.

---

## Decision: doc comments flow from one source to both hover and generated docs

**Rule.** A `///` line comment (exactly three slashes; `//` and `////`+ stay ordinary trivia) is a
**doc comment**. The lexer no longer discards it: `skip_trivia` gathers a run of `///` lines into a
raw span and `lexer_scan` attaches it to the next token via two new `Token` fields (`doc`,
`doc_length`). The parser cleans it once (`tok_doc` strips indent + markers, rejoins lines) and
stores it on the AST — `Decl.doc`, `FnDecl.doc`, `Field.doc`, `Variant.doc`. Exactly **one** corpus
of doc text then feeds **two** consumers: the language server renders it under the signature on
hover and in completion `documentation` (`src/lsp.c`), and `emberc --emit=docs` renders a Markdown
reference page (`src/docgen.c`). The doc generator stops after parsing — docs are surface API, not
semantics — mirroring `--emit=ast`.

**Why.** This is the first slice of the LSP roadmap (`LSP_ROADMAP.md`): make the language server a
*rich* source of language information by routing the author's own comments through the real
frontend rather than a second, divergent extractor. Cleaning doc text in one place (the parser)
means the hover card and the doc page are byte-for-byte the same prose and cannot drift — the same
single-source discipline `include/vocab.def` already enforces for the lexical vocabulary (OFI-033),
one level up in the AST. The CLAUDE.md mandate that `docs/` stay current becomes a generator
invocation instead of a manual chore. Storing the doc as a raw source span on the `Token` (not an
owned copy) keeps the lexer zero-copy; the single cleaned arena string lives only on the AST node.
Type/signature rendering is, for now, duplicated in the generator (tracked as OFI-034).

---

## Decision: the type checker emits a semantic index the language server queries

**Rule.** The checker can build a **semantic index** — a position-keyed table mapping each
identifier's source span to its checker-inferred type and its definition site (`include/semindex.h`,
`src/semindex.c`). It is opt-in: `check_program` takes a trailing `SemanticIndex *out_index`
(`NULL` in batch compilation, so `emberc --emit=run/bytecode/...` pays nothing), and the checker
records an entry whenever it resolves an `EXPR_IDENT` to a local or parameter. The language server
obtains one via `collect_semantic_index` (driver.h) — load + check, no codegen — and answers
`textDocument/hover` and `textDocument/definition` from it: a local/parameter under the cursor is
resolved from the index (its *inferred* type, and a scope-aware jump to its binding) ahead of the
AST/vocab path, so a shadowing binding wins over a same-named top-level declaration. The index owns
its strings (copied in on add), so it outlives the checker's AST arena.

**Why.** Phase 1 hover showed only what the source *spelled* (the AST). The checker already infers
the type of every binding and resolves every name; discarding that after diagnostics meant a `let
x = a + b` hovered as nothing. Routing hover/definition through the checker's own resolution is the
rust-analyzer lesson applied in-tree — one frontend, many projections, no second analysis to drift.
A single position-indexed artifact is also the foundation the rest of Phase 2 builds on
(member completion, find-references, semantic tokens, inlay hints are all "look up the node, read
the index"). Rendering an inferred `SemType` to text needs the checker's type tables, so the
renderer (`render_type`) lives in `check.c`; this is a fourth type-formatter and is folded into the
OFI-034 unification plan. The index is rebuilt per request (the checker runs on each hover) — fine
for the file sizes a young language sees, and consistent with how `publish_diagnostics` already
re-checks on every keystroke; caching is a later refinement.

---

## Decision: one shared surface-syntax formatter for types and signatures

**Rule.** Rendering an AST `Type`/`FnDecl` to its human-facing surface form ("`[string]`",
"`Box<int>`", "`fn name(a: int) -> int`") happens in exactly one place: `src/typefmt.c`
(`typefmt_type`/`typefmt_fn`), which writes through a tiny `TypeSink { put; ctx }` so each consumer
supplies its own output target. The LSP (hover/completion, into a `JsonBuf`) and the docs generator
(`--emit=docs`, into a `FILE*`) keep thin wrappers that build a sink and delegate. Two nearby
renderers stay separate **on purpose**: `src/ast_print.c`'s `print_type` is a golden-locked debug
AST dump with its own conventions, and `src/check.c`'s `render_type` formats a resolved `SemType`
id (a different input domain — there is no AST `Type *` to walk). typefmt.h records both exclusions.

**Why.** The editor tooltip and the generated reference page describe the same language, so they
must render it identically; before this they were byte-for-byte-identical copies that a single
type-syntax addition (tuples, nullable, …) would have silently split (OFI-034). Centralising the
surface syntax — while *not* over-merging the debug dump or the semantic renderer — is the same
single-source discipline `vocab.def` applies to the lexical vocabulary, one level up in the AST.
The sink indirection is the minimum needed to serve different outputs from one traversal.


## Decision: the example programs are full-compiled by the test suite, not just lex+parsed

The `examples/*.em` showcase programs double as the living integration baseline, but `tests/run.sh`
historically only **smoke-tested** them through lex + parse. That let two flagship examples
(`03_errors`, `05_concurrency`) silently drift off the implemented language — calling functions that
no longer existed and using `?` on a non-`Result` — because nothing type-checked them (OFI-030). The
smoke tier now runs `--emit=bytecode` (full type-check + codegen) on every example. The graphics
examples (those importing `std/draw`/`std/ui`) need the raylib backend natives, which the default
dependency-free build deliberately lacks, so they stay lex+parse in `tests/run.sh` and are
full-compiled in `tests/run-graphics.sh` under `emberc-gfx`. Rule: an example is documentation that
must *also* compile — a showcase that doesn't type-check is a broken doc, and the suite now enforces
it instead of trusting it.


## Decision: the semantic index records every resolved reference, not just locals/fields/methods

The LSP's rich hover and go-to-definition are powered by the checker's position-keyed semantic index
(`include/semindex.h`), built only when the language server asks (NULL = off, so batch builds pay
nothing). It originally recorded three node kinds — locals/params, `obj.field`, `obj.method()` — so
hovering anything else (a free-function call, a type name, an enum variant, and crucially a
cross-module `draw.window`/`draw.RED`) fell back to a same-module name match or returned nothing
(>50% of on-screen tokens were dead). The decision: **record at every resolution site the checker
already passes through**, and enrich each entry to the clangd `HoverInfo` model. A `SemEntry` now
carries a `SemKind` (function/type/variant/constant/module/…), the owning module or type
(`container`), the symbol's `///` doc, a constant's value, a struct field's byte offset+size (Ember
has native layout), and a `def_file`/`def_line` definition site — so the hover card shows
`(kind) scope.name signature`, the doc, and a "declared in file:line" provenance line, and
go-to-definition jumps cross-file into `std/*.em`.

Key enablers, all reusing existing machinery rather than adding a second analysis (the rust-analyzer
lesson the LSP already follows): the shared `typefmt_fn`/`typefmt_type` formatter renders every
signature (hover, docs, completion stay byte-identical — OFI-034); `load_modules` already pulls every
imported module's AST (with file paths + positions) into the checker before it resolves a qualified
call, so the cross-module data was already computed and merely discarded; and `FnSig`/`StructInfo`/
`EnumInfo`/the global-const table gained `decl`/`def_line` back-pointers mirroring the proven
`MethodInfo.decl` pattern. One parser fix was needed: `new_type` recorded `cur(p)` (the token *past*
the type) as a `Type`'s position, so the index keyed type references at the wrong column —
`parse_type` now positions the node at its name token. The index remains single-file (it records all
checked modules at their file-local positions, a pre-existing limitation that hover tolerates because
queries only hit current-file coordinates); cross-file *definition* works via the recorded `def_file`.

A follow-on gap (OFI-038): the built-in **array/string intrinsics** (`a.append(x)`, `s.split(",")`,
`xs.len()`, …) are special-cased directly in `check_call` rather than resolved through a struct's
method table, so they never reached `sem_record_method` and hovering them returned nothing — every
dot-notated *native* method had a blank card. The fix keeps the same principle (record at the
resolution site, render through the shared formatter): a `sem_record_intrinsic` helper logs an
`SK_METHOD` entry at the method-name span for each intrinsic, building the one-line signature from the
receiver/parameter/return `SemType`s via `render_type` and using the receiver type as the card's
container. These methods have no Ember source, so no `def_line` is recorded and go-to-definition on
them is intentionally a no-op.

**Remaining LSP work (deferred by agreement; each is now just "read the richer index").** The index
is the foundation for the features still to come: *find-references* and *rename* (invert the index to
all occurrences of a symbol); *semantic tokens* and *inlay hints* (the inferred type of an
unannotated `let`, on-brand for the LLM-legibility goal); *signature help* (the parameter list while
typing `(`); and *richer diagnostics* (severities, error codes, related-info, code actions — today
severity is hard-coded to error and current-file only). Two structural gaps remain: the index is
single-file, so a hover whose coordinates land *inside an imported file* isn't served yet (cross-file
*definition* already works via the recorded `def_file`), and the import alias in *type* position
isn't recorded. The post-parity differentiator is code actions that surface the verification loop
in-editor — "the prover can discharge this line" / "add a `requires`" from `--emit=prove`, which no
other young language's LSP offers. Deferred perf: incremental document sync + parse caching (the
per-request re-parse is fine at current file sizes, acknowledged in `src/lsp.c`). This list is the
live tail of the now-retired `LSP_ROADMAP.md`.


## Decision: `make install` removes the destination binary before copying (macOS code-sign cache)

The `install` target `rm -f`s `$(PREFIX)/bin/emberc` before `cp`ing the new release binary, rather
than copying over it in place. The reason is a macOS (arm64) trap: the linker ad-hoc-signs every
Mach-O, and the kernel caches that signature's cdhash **keyed by inode**. Copying new content over an
existing file keeps the inode, so the kernel compares the new bytes against the *cached* cdhash, finds
a mismatch, and SIGKILLs the process the moment it execs — "Killed: 9", exit 137, no diagnostics. The
editor (which launches the installed `emberc --lsp`) then shows nothing at all, which is
indistinguishable from a broken feature and cost a debugging round (OFI-040). Removing first gives the
copy a fresh inode with no stale cache entry. The same class of failure is why `install-vscode`
packages a fresh `.vsix` rather than hand-copying files. Rule of thumb for this toolchain: never
overwrite a signed binary in place — `rm` then `cp`, or `mv` a freshly-built temp into place.


## Decision: `>>` is one token, split by the type parser (the C++/Rust/Java trick)

Adding the shift operators meant `>>` must lex as a single token (`TOK_SHR`) so `a >> b` is one
operator — but `>>` also closes nested generics (`Box<Box<int>>`), where it must read as two `>`.
These collide, the classic C++98 `>>`-in-templates problem. We resolved it the way C++11, Rust, and
Java do: lex `>>` greedily as one token, and **split it back into two `>` at the three type-argument
close sites** (`parse_type`, and the local + qualified generic-literal paths) via `expect_type_close`,
which — when it sees a `TOK_SHR` where it wants a `>` — rewrites that token in place into a single
`>` and does *not* advance, so the enclosing list consumes the remaining `>`. (`Parser.toks` is the
lexer's heap buffer; the `const` is only an API contract, so the in-place rewrite is defined.) The
OFI-002 generic-vs-comparison lookahead scanner learned the same arithmetic: a `TOK_SHR` decrements
the angle-bracket depth by two, and overshooting to a negative depth proves the `<` was a comparison.
The alternative — never merging and detecting `>>` by token adjacency in the expression parser — was
rejected: it would push two-token peeking into the precedence climb and make `> >` vs `>>` depend on
whitespace, surprising both humans and LLMs. `<<` needs no such handling — it can never open a
type-argument list, so the lexer always merges it safely.


## Decision: an interface value is a boxed {receiver, vtable} reusing the bounds witness

Dynamic dispatch (an interface used as a value type — `let s: Shape`, `[Shape]`, params/returns/
fields) was built to **reuse the generic-bounds machinery** (OFI-004) rather than add a parallel
runtime. An interface value is `ObjInterface { Value receiver; Value vtable }` — Go's `(data,
itable)` / Rust's `dyn (data, vtable)`. The `vtable` is the **exact same witness record** the
bounds path builds (`build_witness` in check.c): a record of the impl's method fn-indices in
interface-method order. So one witness builder serves both modes, and method dispatch reuses the
indirect-call path: bounds read the fn-index from the witness in local 0 (`OP_CALL_INDIRECT`);
dynamic dispatch reads it from the value's vtable (`OP_CALL_DYN`, which also swaps the interface
value on the stack for its receiver so the callee gets `self`). The upcast is **implicit** at every
widening site, funneled through one `assignable()` helper in the checker that records the witness on
the expression; codegen's `gen_expr` wrapper boxes any expression carrying that annotation
(`OP_MAKE_DYN`), so every value site upcasts uniformly. The interface value **owns** its receiver (a
move type), so `drop_value` releases the receiver at scope exit — no new ownership story.

Two consequences worth stating: (1) **object safety** — a value-type interface may not mention
`Self` beyond the receiver (the concrete type is erased, so there's no second same-typed value to
pass); non-object-safe interfaces stay usable as bounds. This is Rust's object-safety, simplified to
one rule. (2) A fresh vtable is built per upcast (the witness is rebuilt at each boxing site);
sharing one static vtable per (struct, interface) pair is a possible later optimization — the erased,
build-each-time path is correct and was the cheap first cut. SemTypes for interfaces live in their
own `IFACE_BASE` band, mirroring arrays/channels.


## Decision: a bounded generic struct stores its key witnesses in the instance

`Map<K: Hash + Eq, V>` needs to call `key.hash()` / `key.eq()` inside its methods on an
*erased* `K`. The witness (the concrete key type's method table) lives **in the struct instance**,
not threaded through method calls: a bounded generic struct gets one hidden, boxed witness field per
(bounded type parameter, bound) appended after its declared fields, filled at construction (where the
type arguments are concrete) and read from `self` by method bodies. This was chosen over
*param-threading* (passing witnesses as hidden method args at each call site) because a `Map` is a
**value** — stored in a field, returned, put in an array, used behind an abstract type parameter — so
its key behaviour must travel *with the value*, not be reconstructed at every call site. The witness
reuses the bounds machinery exactly: the same `build_witness` record, read with `OP_GET_FIELD` then
`OP_CALL_INDIRECT` (which already decodes native witnesses for built-in keys). Layout/construction/
drop fall out for free: the witness fields are ordinary boxed fields, so the VM allocates, fills, and
releases them like any other. Cost paid: the runtime `StructType` field count must use the *layout's*
count (declared + witness fields), distinct from the codegen `CgStruct`'s user-only count — conflating
the two silently dropped the user fields at construction (the bug that cost one debugging round).

The key type needs only `Hash + Eq` — no `Copy` bound (OFI-042). The map copies keys (store +
rehash): a built-in key (scalar/string/enum) copies cheaply, and a move-type **struct key is
deep-cloned structurally on store** (the runtime's `own_into_slot`, the same recursive deep-clone that
makes aggregates-through-erased-generics sound — OFI-062/063), so the map owns its copy and the caller
keeps theirs, with no double-free (verified VM==native + ASan-clean). Built-in scalar/string
keys satisfy `Hash`/`Eq` via native-encoded witness slots (a witness fn-index ≥ `WITNESS_NATIVE_BASE`
means "call this native", decoded by the indirect-call opcodes) — so primitives "implement"
interfaces without synthesizing per-type shim functions.


## Decision: pointer/buffer FFI reuses the leaf model — heap value as one borrowed leaf, wrapper dereferences

The C FFI's third widening (after scalars and structs-by-value) is pointers, buffers, and opaque
handles (§5h pointers). The boundary stays the **leaf sequence** — no new marshalling machinery — by
treating each pointer-flavoured argument as **one leaf carried as the Ember heap `Value` itself**,
which the registry wrapper dereferences. A `string` arrives as its `ObjString` Value (`AS_CSTRING`
→ `const char*`, already NUL-terminated); a packed scalar array arrives as its `ObjArray` Value
(`->data` + `->length` → a buffer); a `Ptr` carries an opaque C pointer in the int64 slot
(`PTR_VAL`/`AS_CPTR`). This is why no VM change was needed for marshalling: `OP_CALL_C` already hands
the wrapper `vm->sp - in_leaves`, and the wrapper now reads a heap pointer off a slot instead of a
scalar. Leaf kinds extended: `'p'` (const char\*), `'b'` (buffer), `'P'` (opaque Ptr), each one slot.

The alternative — flattening a buffer into *two* leaves (pointer + length) pushed by codegen — was
rejected: it would have meant codegen synthesizing the length and the VM expanding a single Ember
value into two stack slots, duplicating state the `ObjArray` already holds. Letting the wrapper read
`->length` keeps the one-value-one-slot invariant the rest of the call path assumes.

**Borrow, not transfer, is the ownership rule, and it reuses the existing temp-drop machinery.** A C
call borrows its heap arguments for the call's duration: the checker (`check_fn_call`) skips the
`consume` it would do for an ordinary call (no incref of a string arg, no move of an array arg), so
the caller keeps ownership and a named binding is untouched. The one thing the caller must still do is
release a fresh **owning temp** passed by borrow (the literals in `fopen("f","r")`, a built array) —
which is exactly what `is_owning_temp` already identifies and the `drop_mask` + `OP_PICK` +
`OP_DROP_UNDER` path already emits for owned struct temps (OFI-027). So the extern codegen mirrors the
direct-call drop path verbatim, swapping `OP_CALL` for `OP_CALL_C`. `mut` is allowed on a buffer
parameter (it asks the call site for a writable array and documents that C writes in place); arrays
are uniquely-owned and mutable anyway, so a non-`mut` buffer write would also be sound — `mut` is the
honest signal, not a soundness gate. Returning C-owned memory is deferred (OFI-043): the borrow model
owns nothing C owns, so there is no free/copy ownership question to get wrong yet.


## Decision: wrapping arithmetic is three function builtins, not operators (OFI-041)

Hashes/PRNGs/checksums need modular (2^width) integer arithmetic, but Ember's `+ - *` trap on
overflow by design (OFI-005). The wrapping direction is exposed as three **builtins** —
`wrapping_add`/`wrapping_sub`/`wrapping_mul(a, b)` — not as `&*`-style operators. Karl's call. The
function form (a) adds no new sigils and no precedence rules, sidestepping the `>>`-token /
nested-generics lexer churn that operators would reignite; (b) keeps wrapping **unmistakably
explicit**, the same philosophy as `move` for ownership — a model never reaches for it by accident,
which trapping-by-default exists to ensure; (c) implements like the existing `to_int`/`len`/`clock`
intrinsics — a checker special-case (two same-width integer operands → that width, sets `num_kind`)
plus codegen that pushes both operands and a width byte. No grammar change.

The runtime is three new opcodes `OP_WRAP_ADD/SUB/MUL`, each carrying the one-byte numeric kind (the
same encoding as trapping `OP_ADD`: 0 i64, 1–3 i8/i16/i32, 4–6 u8/u16/u32, 7 u64). They do the
arithmetic in `uint64_t` (defined wraparound at 2^64) and then truncate to the operand width and
reinterpret — sign-extending for the signed kinds — so each wraps at its own width (`200u8 + 100u8 ==
44u8`, two's-complement for `i8`). Dedicated opcodes (rather than a "wrapping" flag on the existing
arithmetic kind byte) keep the change isolated and avoid touching every `OP_ADD/SUB/MUL` emit site —
the operand-count discipline the VM relies on (see the opcode-operand note). Showcase + regression:
FNV-1a written in pure Ember (`tests/run/wrapping_arith.em`).


## Decision: UTF-8 strings at code-point granularity — byte-level len/bytes, code-point chars/char_count

Ember strings already stored UTF-8 bytes; the Unicode work made the *operations* honest. Karl chose
**code points** as the "character" unit (over grapheme clusters) and **byte length** as `.len()`
(over code-point count). Both choices are manifesto-driven:

- **Code points, not graphemes.** A code-point view needs only a stateless UTF-8 decoder
  (`utf8_decode`/`utf8_encode` in vm.c — no tables); grapheme clusters need the large,
  Unicode-version-dependent segmentation tables, which would add a re-shipped data dependency and
  fight the zero-dep principle. Code points are correct for the overwhelming majority of text work
  and match the Rust `chars()` prior an LLM already holds.
- **`.len()` stays bytes (O(1)); `.char_count()` is the O(n) code-point count.** Byte length is the
  storage/FFI-buffer size and is O(1); making `.len()` O(n) would hide a loop behind a name that
  reads constant-time. `.bytes()` (→ `[u8]`) and `.char_count()` name the two costs explicitly, so
  neither is a silent surprise. (The Python prior — `len` = characters — was the case *against*;
  the O(1)/FFI honesty won.)

So `.chars()` decodes to code points (was: one string per byte — a latent bug for any multibyte
input), `char_code`/`from_char_code` are code-point decode/encode (1–4 bytes), and `.split()` needed
no change (UTF-8 is self-synchronizing, so a byte `memcmp` split never cuts mid-character). Decoding
is **lenient**: an invalid/overlong/surrogate/truncated sequence yields U+FFFD and advances one byte,
so no string operation can fail and `read_file` never rejects odd bytes. New opcodes
`OP_STR_CHAR_COUNT`/`OP_STR_BYTES`; storage, concat, and interpolation were already UTF-8-correct.


## Decision: slices are borrowed, non-escaping Slice<T> views — sound without lifetime inference

A slice is a zero-copy `(pointer, length)` view into an array. The hazard: Ember arrays are mutable
move types whose buffer **reallocates on append**, so a naive view dangles if the source is appended-
to, moved, or dropped. The fully general fix (returnable views) is the deferred lifetime-inference
tail (OFI-009). Karl chose the version that delivers zero-copy views **without** reopening lifetimes:
compile-time borrow-freeze, **non-escaping**.

`Slice<T>` is a **distinct type** (band `SLICE_BASE`, sharing the array element table). Making it
distinct is what buys soundness cheaply: escape prevention falls out of the type system. The escape
surface is closed by **default-deny** — a checker flag `allow_slice` is set true only while resolving
a parameter or `let` annotation, and `annotation_type` clears it for every nested type; so a slice may
appear *only* at the top of a parameter or let annotation, never as a return type, struct field,
array/channel element, or generic argument. A missed allow site is merely restrictive, never unsound.
The runtime value is an ordinary `ObjArray` with a `borrowed` flag: `data` points into the source
buffer, so all read opcodes (`OP_INDEX`, `OP_ARRAY_LEN`, for-iteration) work unchanged; drop frees
only the header (never the borrowed buffer or its elements), and `append`/`set`/`pop` trap on it as
defense behind the static checks.

Soundness rests on two binding-level rules beyond the type:
- **Freeze:** slicing a named array local sets a `frozen` flag on it for the rest of its scope
  (conservative, never unfrozen). A frozen local rejects `append`/`remove_last`, element and whole
  reassignment, moves, and `mut` arguments — anything that could realloc or free the viewed buffer.
- **Named source only:** the sliced expression must be a named local/param, so the view borrows
  something whose lifetime encloses it; slicing a temporary (`mk()[0..2]`) is rejected. Combined with
  no-escape, the source always outlives the view, so drop ordering is automatically safe.

The companion **`arr.slice(lo, hi)`** copies into a fresh owned `[T]` (escapable). Its boxed-element
copy retains each element (`OBJ_RETAIN`) for the refcounted kinds; a nested-array element (a boxed
move type) would alias unsoundly, so the checker rejects `.slice()` there (deferred). Deferred
overall: returnable/storable views, array→slice auto-coercion, and mutable write-through slices.

---

## Decision: a native backend that lowers the AST to C, with the VM as reference semantics

**Rule.** Ember gains a **second lowering** alongside `src/codegen.c`'s AST→bytecode: `src/cgen_c.c`
walks the *same* checked AST (reusing the checker's `resolved_fn`, `num_kind`, `MonoPlan` and
`StructLayout`) and emits a self-contained **C** translation unit. `emberc --emit=c` writes the C;
`emberc -o <bin> file.em` writes it and invokes the system C compiler to link it against the runtime
in `include/ember_rt.h`, producing a standalone binary. The **bytecode VM stays the canonical
reference semantics** — the analysis/verification emit modes (`run`, `check`, `replay`, `prove`,
`trace`) remain VM-only, native is the *release/standalone* path. The two are held in lockstep by a
**differential test** (`tests/native/`): every program is run on the VM and as a compiled binary and
their stdout must match. The target is **C, not LLVM IR or assembly**, and the only build dependency
is the platform C compiler — no new third-party libraries (the empty-dependency-tree decision above).
Native concurrency, when it lands, uses the **threaded** runtime (`-DEMBER_PARALLEL`); the serial
cooperative scheduler's `VM_YIELD` unwinds the dispatch loop and has no straight-line-C analogue.

**Why.** This is step 1 of making Ember a systems language that could eventually target bare metal:
you cannot run an OS as a guest inside a VM that itself needs an OS, and interpreter dispatch caps
performance. Lowering from the **AST** rather than the bytecode is the load-bearing choice. Bytecode
is stack-based and erased; bytecode→C would either reconstruct the expression trees the typed AST
already provides (the same work, backwards, on a lossy form) or emit an unrolled interpreter (slow,
unreadable, a dead end for a future freestanding mode). AST→C emits natural C (`a + b` → `a + b`) and
keeps the road to bare metal open. The manifesto's "one backend" (§5c) is preserved at the layer that
matters — there is still **one front-end and one reference semantics** (the VM); the cost of a second
*lowering* is that each language feature is lowered twice, and that risk is contained by the
differential test, which doubles as a demonstration of Ember's verification/determinism north star
(two independent implementations that must agree). Milestone M1 (the scalar walking skeleton) is
header-only — `ember_rt.h` re-expresses the VM's width-aware arithmetic as `static inline` helpers so
results are bit-identical; structs/strings/arrays, generics, closures, FFI and concurrency arrive in
later milestones as a real `libember_rt` extracted from `src/vm.c`. Known deferred gaps are tracked
as **OFI-051**.

---

## Decision: value-type structs lower to real C structs in the native backend

**Rule.** A value-type (all-scalar) Ember struct is emitted as a **real C struct**
(`typedef struct { Value f0; Value f1; … } em_s<sid>;`) and used by value: construction is
a C compound literal `((em_s<sid>){ … })`, a field read is `obj.f<idx>`, a field write is
`lvalue.f<idx> = v`, and a struct binding/param/return carries the C type `em_s<sid>`. A
`mut self` receiver is passed **by pointer** (`em_s<sid> *`, bound to `(*a0)`) so mutations
reach the caller; everything else is a by-value copy. There is **no heap allocation and no
drop** for value structs — C's value semantics give moves, copies, and nesting for free.

**Why.** The C backend's first cut boxed *everything* as a uniform `Value` (an M1
simplification), heap-allocating and reference-counting each struct. That is correct for
borrows but **double-frees on moves** (`let q = p`, move-params): two boxed aliases each
free the same object, and the checker's ownership flags don't help because they are computed
for the VM's value-type (multi-slot stack) representation, where there is nothing to drop.
All-scalar structs are *value types* in Ember (the VM keeps them as stack slots, never heap),
so the native backend must too. Real C structs are the **native-layout** representation this
backend exists to produce — fastest, idiomatic, and correct-by-construction for value
semantics. (Karl chose this over mirroring the VM's loose multi-slot or patching the boxed
model; the alternatives were a uniform-`Value` detour, not the native destination.)

**Typing the values.** A binding/param/return's struct id comes from the checker's flags
where set (`inline_struct_id` on an immutable `let`/borrow param, `ret_struct_id` on a
function), and otherwise from the declared type or initialiser — because the checker flags
only *borrow* params and *immutable* lets (mut/move params, `self`, and `var` structs are
left boxed in the VM and so unflagged). `src/cgen_c.c` resolves these via `sid_of_struct_type`
(param/return type → sid) and a recursive `struct_sid_of` (an expression's struct id). The
struct-specific boxed runtime helpers (`em_struct`/`em_get_field`/…) were removed; the boxed
object runtime (`alloc_instance`/`drop_value`/`field_loc`) stays for the VM and for the
imminent boxed aggregates (enums). Differential-tested across moves, mutation, `mut self`,
nested structs, and methods (tests/native/struct*.em).


## Decision: boxed-aggregate runtime helpers mirror the VM — read/borrow, never consume

**Rule.** The native backend's runtime helpers for boxed aggregates (enums, arrays, and
strings — everything that is *not* a value-type struct) **read their operands and never drop
them**, exactly as the VM's opcodes do. `em_add` (string concat) allocates a fresh result and
leaves both operands alone; `em_print`/`em_println` write a value and leave it alone; `em_index`
borrows. Operand and temporary lifetimes are managed the same way the VM manages them: a
named/`var`/param binding is freed by the **checker's drop flags** (the `drop_value` calls the
emitter already places at scope/return/block/loop-body exits, and a consuming param's
scope-exit release), and a literal/intermediate **temporary** is reclaimed by the **exit sweep**
(`rt_free_objects`, which frees every still-live object regardless of refcount — the VM relies
on the identical sweep).

**Why.** The first cut of string concat and print made the helpers *consume* (drop) their
operands, on the assumption that a borrowed operand would have been retained by the caller
(`moves_local==2`). That assumption was wrong and produced two crashes: a string **parameter**
passed to `em_add` was dropped by the concat **and** again by the param's scope-exit release
(double-free → `SIGABRT`), and `println(msg)` dropped a **reused binding** before `msg.len()`
read it (use-after-free). The VM never has these problems because `OP_ADD` and `print_value`
only read — the checker's drop discipline owns every free. Matching that rule (helpers don't
consume) makes the native backend's refcounting fall out of the flags the emitter already
honors, with no special retain/consume bookkeeping.

**Known gap.** The C backend does not yet emit the checker's `drop_mask` / `release_temp` for
owned **temporary call arguments**, so a temp argument (a string literal, a concat result, an
enum/array literal passed straight into a call) leaks until the exit sweep. This is **bounded**
(reclaimed at process exit, output identical to the VM) but grows peak memory in a long-running
loop. The proper fix — evaluate temp arguments into C locals and drop them after the call —
is a tracked follow-on (OFI-051). Verified by the enum (100k-iter), array (50k-iter), and
string (20k-iter concat/interpolation + aliased binding) differential stress tests.


## Decision: generics are erased to one C function; closures use a uniform em_invoke trampoline

**Generics — erased, not monomorphized.** Ember's generics are erased in the VM (one body over a
uniform 16-byte `Value`; the `MonoPlan` only duplicates table *slots* for call-target identity, never
specializes a body). The native backend keeps that model exactly: a generic function lowers to **one**
C function over `Value`, and every instantiation's call routes to that single slot via the call's
`resolved_fn` — the per-instantiation slots the monomorphizer appends are collapsed away (they would be
byte-identical). No monomorphization machinery is ported. `Option`/`Result` are the boxed enums the
backend already emits, so generics over them are free. The `?` operator lowers to a statement-expression
that, on the success variant, moves the payload out (retained) and frees the shell, and on Err/None runs
the function's owning-local drops and `return`s the operand early (a `?`-bearing function always returns
a boxed enum, so the C return type is `Value`).

**Why erased and not monomorphized.** The VM is the differential-test reference; matching its erased
semantics keeps outputs identical with the least code. Monomorphization would mean re-lowering each
generic body per concrete type with a type substitution threaded through the emitter — more machinery,
and it would diverge from the reference unless kept perfectly in step. The one thing erasure cannot do
for free is a generic instantiated over a **value-type struct**: the erased body is over boxed `Value`,
but a value struct is a real C `em_s<sid>`. That is rejected with a clear error pending the struct↔box
bridge (the same bridge `dyn` interfaces need), not miscompiled.

**Closures — boxed ObjClosure + a uniform indirect-dispatch trampoline.** A closure is the same boxed
`ObjClosure` the VM uses (a lifted-function index + by-value captures, refcounted), so it rides the
existing `Value` lane and the checker's move/drop flags already align. Construction is `em_closure(ctx,
fn_index, capture_count, …)`; the emitter reads the captures by **name** from the lifted function's
leading parameters (the checker names them after the enclosing locals, so no AST change is needed). The
indirect call is the crux: C has no uniform function-pointer call across heterogeneous arities, so the
backend generates a single **`em_invoke(ctx, fn_index, slots)`** trampoline — a `switch` over every
all-`Value`-signature function that calls the concrete `em_fn_<k>(slots[0]…)` with its exact arity. The
runtime `rt_call_closure` lays out `[captures…, args…]`, retains both (the lifted body releases every
refcounted parameter on return — the erased-T runtime retain that keeps higher-order generic calls
sound), and dispatches through `em_invoke`. `em_invoke` is emitted with external linkage so a
closure-free program, which never references it, does not trip `-Wunused-function`. A closure whose
signature mentions a value-type struct is deferred to the same struct↔box bridge.


## Decision: a struct is a value-type C struct only if all-scalar; heap-bearing structs are boxed

**Rule.** In the native backend a struct lowers to a real C value-type (`em_s<sid>`, value semantics,
no drop) **only if it is all-scalar recursively** — no string/array/enum/closure/interface field
anywhere, only scalars and nested all-scalar structs (`is_value_struct` in `src/cgen_c.c`, read from the
layout's per-field `kind`/`field_struct`). A struct with any heap field (a `Config { host: string }`, or
the stdlib `Map`/`Set` with their bucket array + witness fields) is instead a **boxed, refcounted
`ObjStruct`** — exactly as the bytecode VM (the differential reference) represents it. Construction is
`em_struct` (heap-allocates, moves fields in); a field read is `em_enum_field`; a field write is
`em_set_field` (drops the overwritten boxed value first); a method takes a boxed `Value self` and reads
fields through it (a `mut self` mutates the shared heap object); `drop_value` releases it and its fields.

**Why.** The first cut lowered *every* struct to a value-type C struct, which never drops. That is correct
for all-scalar structs (the VM keeps those as stack slots too) but **leaks the heap field of any struct
that has one** — and silently, because the differential test checks stdout, not memory. The checker
already classifies structs this way (its all-scalar / `nested_inline_sid` rule decides value-type vs
boxed move type), so the backend must match: representing a heap-bearing struct the way the VM does makes
the checker's move/drop/refcount flags line up with the representation, which is the backend's governing
principle (cf. the value-struct and boxed-aggregate decisions above).

## Decision: native drop discipline mirrors the VM's ownership, with interning and consuming operators

**Rule.** Generated C must be leak-free for long-running programs, not merely output-correct. The backend
emits drops/retains so every owned heap temporary is released exactly once, matching the VM's ownership
model and, where the VM relies on it, its **string-literal interning**:

- **String literals are interned** at their emit site (one heap object per literal, returned retained per
  use) — a literal in a loop is one allocation, as in the VM.
- **`+` (concat) and `==`/`!=` consume their operands** (`em_add`/`em_eq_op`/`em_neq_op` drop both). The
  emitter retains a *borrowed* operand at the call site (`emit_concat_operand`) so the consume balances and
  a borrowed string parameter is not double-freed; an owned temporary is freed by the consume.
  `em_to_string` returns a string input *retained* so an interpolation fold can consume it.
- **Owned temporary call arguments** are dropped after the call via the checker's `drop_mask` (a masked
  argument is always a single boxed `Value`, so the drop is uniform). **Bounded-generic witness records**
  and **boxed value-struct returns** are likewise dropped after the call (`emit_generic_call`).
- **An escaping boxed-field read** (`return c.host`, `let x = c.host`) is RETAINED so it survives the
  owning struct's drop; a `.len()` on a temporary receiver drops the receiver.

**Why.** A native backend that targets standalone / long-running / eventual-OS programs cannot leak per
operation. The differential harness guards *output*; memory is verified separately by peak-RSS sweeps
(`/usr/bin/time -l` over million-iteration loops) — flat RSS, not just matching stdout, is the bar. Notably
this is *stricter* than the VM in places: returning a boxed struct's heap field worked in the VM only by
reading freed memory (a latent use-after-free the boxed representation surfaced), and `==`-of-temporaries
leaks in the VM; the native backend fixes both. (OFI-052.)


## Decision: native concurrency runs on OS threads with a thread-local context and a conditional parallel build

**Rule.** `spawn` / `nursery` / typed channels compile to real OS threads (pthreads), mirroring the VM's
threaded (`-DEMBER_PARALLEL`) runtime rather than its serial cooperative scheduler — a compiled binary has
no dispatch loop to yield out of, so the cooperative model has no straight-line-C analogue. A spawned task
runs `em_invoke(fn, args)` on its own thread with a **thread-local runtime context** (`_Thread_local g_em`):
each worker allocates into its own lock-free arena, and the only contended state is the atomic refcount on
shared values. A `nursery` collects its spawns into a task list and `em_run_nursery` launches one thread
per task and joins them all; a finished worker merges its arena into a shared graveyard under one lock; a
cross-thread free defers via `Obj.home` (left on the home list, collected by the exit sweep). Channels are
the VM's `ObjChannel` (pthread mutex + dual condvars: `not_empty`/`not_full`); `recv` yields `Option<T>`.
The VM's per-nursery **deadlock detector is ported**: when every task in a group is blocked on a channel
and none can proceed, it reports once and aborts (the binary `exit(70)`s rather than hanging).

The build is **conditional**: `emberc` detects whether a program uses concurrency (a `spawn`/`nursery`
anywhere) and only then compiles the generated C with `-DEMBER_PARALLEL -lpthread` and links a parallel
runtime variant (`libember_rt_par.a`). A serial program links the default runtime unchanged — no atomic
refcounts, no pthread, no thread-local-access cost.

**Why.** Threads are the only model that maps to compiled code, and per-worker thread-local contexts keep
the hot path (allocation, same-thread free) lock-free — the contention surface is exactly the shared
refcount and the once-per-worker arena merge, matching the VM's parallel design. The thread-local context
avoids threading an explicit `ctx` parameter through every generated `em_fn` (a pervasive, invasive
change) for the common serial case. The conditional build keeps the native backend's reason for existing —
speed — intact for non-concurrent programs: they pay nothing for a feature they don't use. The ABI
(`ObjChannel` size, refcount ops) must agree between the generated C and the runtime library, which the
conditional build guarantees by compiling both with the same `-DEMBER_PARALLEL`. (Deferred: spawn of a
method/closure or a bounded-generic function. M4.)




## Decision: native builtins, conversions, and string/array methods are runtime functions; the FFI reuses the registry (M5)

**Rule.** The native backend's builtins are emitted as straight C calls into the runtime library, ported
from the VM's opcode semantics so `tests/native/` diffs bit-for-bit. The registry-driven natives
(`read_line`, file I/O, libm `sqrt`/`pow`/…, `char_code`, `parse_float`, `concat`, `args`/`env`/`exit`, …)
route through one dispatcher `em_native(ctx, nid, argc, args)` keyed by the same `builtin.h` ids the VM
uses — *minus* the verification/nondet and graphics paths, which are VM-only (native has no record/replay,
so `random`/`clock` read the real source directly). `print`/`println` keep their own emitter path. Numeric
conversions lower to `em_to_float`/`em_to_int`/`em_conv` (the last trapping on out-of-range like `OP_CONV`);
`clock`→`em_clock`, `len`→`em_array_len`, wrapping arith→the inline `em_wrap_*`, and a bare `assert` to a
hard `em_assert` check (contracts proper stay release-elided). String methods (`chars`/`split`/`bytes`/
`char_count`/`parse_int`) and array methods (`remove_last`/`slice`) are runtime functions that allocate a
fresh result, mirroring `OP_STR_*`/`OP_ARRAY_POP`/`OP_SLICE_COPY`; UTF-8 decode/encode moved from `vm.c`
into `runtime.c` so the library owns them. `args()` reads `em_argc`/`em_argv`, which the generated
`main(argc, argv)` sets from `argv + 1` (skipping the binary name, matching the VM's "args after the source
file"). The **FFI reuses the VM's path**: an `extern "c"` call lowers to `em_ffi(ctx, idx, rsid, argc,
leaves)` → `cextern_call` — the same in-tree typed-wrapper registry (no libffi), now compiled into
`libember_rt.a`/`_par.a` (with `cextern.c`). Args are passed as one borrowed scalar leaf each (string→
`const char*`, packed array→buffer, opaque `Ptr`); a scalar result is the leaf, a struct result is
reassembled via `em_box_struct`.

**Two drop-discipline corrections this milestone (both pre-existing, exposed by the new array/string
work).** (1) **Aliasing reads of an erased value retain generically.** The checker marks a read
`moves_local == 2` when an erased type-parameter value (possibly refcounted at run time) is read from an
existing owner — a local binding, a struct/enum field (`GET`), or an array element (`INDEX`) — and aliased
into a NEW owning slot (append, let, store, moved arg, return). The VM applies a trailing `OP_INCREF`
generically across all those kinds; the emitter now does the same in `emit_expr_raw` (an `IS_OBJ`-guarded
retain), where before it only covered `EXPR_IDENT` — so `out.append(xs[i])` and `e.key` in a rehash no
longer alias one refcount across two owners (the `stdlib_map_resize` double-free). (2) **A consuming
operator / borrowing method on an `arr[i]` element retains/does-not-drop it.** `em_index` BORROWS (the
array keeps ownership), so a `==`/`+` operand that is `arr[i]` is retained before the consuming
`em_eq_op`/`em_add` (`emit_concat_operand` now covers `EXPR_INDEX`), and a method receiver that is `arr[i]`
is treated as a borrow, not an owned temporary to drop (`recv_is_borrow`).

**One representation rule.** A monomorphized generic-struct instance (`base_id != its own sid`, e.g.
`Box<int>`) is **never** a value-type C struct, even when all-scalar: the backend erases generics to one
method body over a uniform boxed `Value`, so an `em_s` instance would clash with the method's `Value` self/
result. Boxing every generic instance (uniform with how `Map`/`Set` are already boxed for their heap
fields) makes construction/field-access/dispatch consistent; only the in-memory rep changes, the
differential output does not.

**Why.** Porting the opcode bodies as runtime functions (rather than re-deriving them) keeps the native
result identical to the reference VM by construction, and keeps the generated C small (straight calls, no
inlined logic). Reusing `cextern_call` for the FFI means the boundary semantics (the typed-wrapper ABI,
struct-by-value via the system C compiler) are defined once and shared — the later optimisation of emitting
direct C calls can come if profiling ever wants it. The drop-discipline fixes were latent gaps the M5
array/string paths finally exercised; fixing them in the generic `moves_local`/borrow machinery (not
per-call-site) keeps the emitter aligned with the VM's single ownership model. With M5 the native backend
compiles the core language; the residual constructs (OFI-054) error cleanly rather than mis-compile.




## Decision: the cgen resolves a type name by SCOPE, never bare name; single-byte opcode ids are guarded

**Two hardening rules, settled while clearing the OFI backlog (OFI-053, OFI-047).**

**(1) Generic-scope-aware type resolution in the native emitter.** `src/cgen_c.c`'s `sid_of_struct_type`
previously mapped a type name to a value-struct id by a bare name match against the struct table. That
silently collided with generics: inside `Box<T>`/`Map<K, V>` a type-parameter name (`T`, `V`) that matched
a user `struct T`/`struct V` resolved to that struct, mis-typing the erased method's param/return (`em_s`
where a boxed `Value` was meant) → broken C. The rule is now: **a type name that is a generic parameter of
the function being emitted, or of its owning struct, is ERASED (returns -1) before any by-name lookup** —
mirroring exactly what the checker's `annotation_type` does (it resolves an in-scope type-param name ahead
of struct names). The owning struct's generic params reach the emitter via a per-fn-slot `owner_generics`
table built beside `fn_by_fi`. Principle: **the cgen must never guess a type by name where the checker used
scope** — the two front-ends share one notion of what a name means, and the cgen is a consumer of it.

**(2) Single-byte opcode id operands are range-guarded, not widened.** `OP_NEW_STRUCT`/`OP_NEW_ENUM`/
`OP_MAKE_CLOSURE` encode their type/fn id in one byte. Their id spaces are sums of separately-capped pools
(structs + monomorphized instances; the whole fn table + lifted lambdas), so an id could exceed 255 and wrap
— the OFI-007 miscompile class, for one-byte operands. Rather than widen the operands (which would churn the
opcode operand-count table, the VM decoder, and the disassembler for headroom only *call* sites need), a
guard helper `emit_u8_id` turns an out-of-range id into a clean compile error. This completes the OFI-007
widening decision for the remaining single-byte id operands: **guard where a byte is sufficient for every
real program, widen only where the ceiling is genuinely reachable (calls).**




## Decision: a value-struct in an aggregate round-trips as an em_s via box-on-store / unbox-on-read (M5+)

**Rule.** When a value-type struct flows into a *boxed* aggregate — an array element, an enum payload, a
generic container — the native backend stores it BOXED (an `ObjStruct` whose packed bytes the VM also uses)
and, on the way out, **unboxes it back into a C `em_s` at the binding/use site**, so the value-struct
representation is uniform end-to-end. Concretely (OFI-054 closure): an inline-struct array element
(`arr[i]`, `arr.remove_last()`) and a value-struct enum-payload match binding (`case Some(v)`) each
*produce* a boxed copy at runtime, and the consuming site — `emit_index`, the `let` binding, the match
case — emits an `em_unbox_struct` into an `em_s`. The checker stamps the element/payload struct id where it
knows the type (`index.inline_struct_id`, `Pattern.binding_struct[]`, and the array literal's
`elem_struct_id`) so the emitter knows when to unbox. Arrays of structs use a packed inline-struct buffer
(`em_struct_array` / the `AEK_INLINE_STRUCT` path in `em_index`/`em_array_append`/`em_set_index`/
`em_array_pop`), mirroring the VM's `OP_NEW_STRUCT_ARRAY` byte-for-byte; a heap-bearing element struct's
sub-fields are retained/released by the existing `struct_elem_retain`/`struct_elem_release` (a no-op for an
all-scalar element). Slice VIEWS `arr[lo..hi]` are a borrowed zero-copy `ObjArray` (`em_slice`), safe
because the checker freezes the source and forbids the view escaping — `drop_value` frees only the slice
header. FFI struct-by-value arguments flatten recursively to their scalar leaves (`em_s.f0.f1…`) into the
`cextern_call` leaf array.

**`em_box_struct`/`em_unbox_struct` are recursive (leaf-by-leaf), not a memcpy.** The C `em_s` stores every
scalar as a 16-byte `Value`; the packed `ObjStruct` buffer stores each at its natural width — so a whole-
struct `memcpy` between them is unsound. Both helpers walk the layout (`box_pack_struct`/
`unbox_flatten_struct`), recursing through nested inline-struct fields and converting each scalar leaf at
its offset. The flat case (no nested fields) is one `value_box`/`value_unbox` per field, byte-identical to
before. This makes them correct for value-struct round-trips of any depth at zero call-site cost.

**Deferred (clean error, OFI-054): a NON-FLAT struct in a boxed aggregate.** Boxing a struct with a nested
inline-struct field now packs correctly, but the boxed field-READ path (`em_enum_field` materialising an
inline-struct sub-field as its own boxed copy, with the matching drop) and boxed construction with inline
fields are not wired, so reading one back would crash — rejected cleanly until that lands. The VM stores
nested struct fields boxed, so this is purely a native-rep gap, not a language one.

**Why.** Unboxing at the binding/use site (rather than keeping aggregate elements boxed everywhere)
preserves the value-struct model — field access is direct C member access, value-copy semantics fall out of
C, and no per-use boxed-temp drop discipline is needed — at the cost of one unbox per read, which is exactly
what the VM does too. The checker-stamped struct ids keep the emitter from guessing types, and the
recursive box/unbox keeps one code path correct for both flat and (future) nested structs.




## Decision: the native backend compiles everything the VM accepts — non-flat structs round-trip leaf-by-leaf (OFI-054)

**Rule.** The native backend (AST→C) accepts the same programs as the bytecode VM — there are no
representation-driven carve-outs ("works unless the struct contains a struct"). A value struct that crosses
into a *boxed* aggregate (array element, enum payload, boxed-struct field, interface receiver, or an erased
generic by value) is boxed into an `ObjStruct` and unboxed back into a C `em_s` at the use site, at any
nesting depth.

**Non-flat structs box/unbox leaf-by-leaf, never by memcpy.** A struct with a nested inline-struct field
(`Line { a: Pt, b: Pt }`) is non-flat: the C `em_s` stores every scalar leaf as a 16-byte `Value`, while
the packed `ObjStruct` buffer stores each at its natural width — so a whole-struct memcpy between them is
unsound. `em_box_struct`/`em_unbox_struct` recurse the layout (`box_pack_struct`/`unbox_flatten_struct`),
converting each scalar leaf at its offset; the flat case (no nesting) is one `value_box`/`value_unbox` per
field, byte-identical to before. Boxed-struct *field access* mirrors the VM's opcodes: reading an inline
field materialises a fresh boxed copy (`em_struct_field_inline` = `OP_GET_FIELD`), and constructing a boxed
struct with an inline field builds-then-places (`em_struct_empty`/`em_struct_put_field`/`em_struct_put_inline`
= `OP_NEW_STRUCT`). The one-level `struct_elem_retain`/`release` walk is sufficient because the checker
classifies a field as inline only when it is *recursively all-scalar* — an inline field never hides a heap
leaf.

**Erased ownership: an inline-field read in generic code is owned and must be dropped.** The subtle corner
is a generic struct with a value-struct key reached through a bounded method (`self.k.eq(other)`,
`Map<Pt,V>`-shaped). `self.k` reads an inline field at runtime — owned when the concrete key is a value
struct, borrowed when it is a string/scalar — and the *erased* emitter can't tell which. So a bound-method
operand is read with `em_field_owned` (materialise inline / retain heap / copy scalar → always owned) and
dropped after the indirect call, and the method-call path now honours `drop_mask` for boxed value-struct
args. Without this, a value-struct key leaks its materialised copy through every witness dispatch (measured
258 MB → 1.4 MB flat over 2 M iterations). `spawn` of a bounded generic threads the witnesses as leading
args and `em_invoke` gained a witnessed-function case (it formerly skipped every bounded-generic function,
which only indirect dispatch — i.e. spawn — reaches).

**Why.** Boxing-on-cross with unbox-at-use preserves the value-struct model (direct C field access, value-
copy semantics, no per-use boxed-temp discipline) while matching the VM's output exactly — the differential
suite is the proof. Mirroring each runtime helper line-for-line on a named VM opcode keeps refcounting
correct without a sanitizer (verified by behaviour: differential output + flat-RSS stress). The result: one
front-end, two execution strategies, and the native binary is a faithful release build of any program the
reference VM runs.






## Decision: AddressSanitizer is now a supported verification path (`make asan` / `make asan-par`)

**Context.** Memory-correctness work (ownership/refcount drop discipline, the native box/unbox, FFI,
cross-thread frees) was historically verified *by behaviour only* — a checksummed flat-RSS stress — because
the older Apple clang's ASan runtime **hung at startup** on this machine (Darwin 25.5/arm64), even on a
hello-world. That was a toolchain bug, not ours.

**Change (2026-06-17).** Karl updated to **Apple clang 21.0.0**, which fixes the hang. ASan now runs
normally (planted heap-overflow is reported with a trace; instrumented `emberc` runs a 100k-alloc program
in ~0.4 s). Added two Makefile targets mirroring the `release` variant pattern: **`asan`** →
`build/emberc-asan` (`-O1 -g -fsanitize=address -fno-omit-frame-pointer`) and **`asan-par`** →
`build/emberc-asan-par` (same + `-DEMBER_PARALLEL=1`, to exercise the channel/nursery cross-thread paths).
Run with `ASAN_OPTIONS=detect_leaks=0 build/emberc-asan --emit=run <file.em>`.

**Scope.** ASan covers the temporal/spatial bugs (use-after-free, double-free, heap-overflow) that RSS
stress can't see. It does **not** cover leaks — **LeakSanitizer remains unsupported on macOS** — so leak
verification stays RSS-based. ThreadSanitizer (data races) is a separate, not-yet-wired build. The
native-backend path (compiling emitted C with `-fsanitize=address` against an ASan runtime lib) is the
highest-value not-yet-wired check, since that drop discipline was RSS-only.

**First result.** A sweep of the full runnable corpus (265 programs: tests/run + tests/native + examples +
benchmarks) under `emberc-asan` reported **0 ASan errors** — the serial VM + runtime are clean under real
instrumentation, corroborating the by-behaviour record.

(Also added the `key_repeat(keycode)` graphics native — `IsKeyPressedRepeat` — so text fields get
press-then-repeat editing keys; a minor primitive alongside `key_pressed`/`key_down`.)






## Decision: a borrowed value-struct exploded into a multi-slot param must not reclaim its shell

**Context (OFI-058).** When a value struct is passed to a function whose parameter is stored MULTI-SLOT
(value-types 3b), codegen explodes the boxed struct into one stack slot per leaf with `OP_UNBOX_STRUCT`,
which — by design for a *consumed* fresh temporary — `reclaim()`s the shell after exploding (the leaves
ADOPT its references; ownership transfers). The bug: codegen emitted this reclaiming form for a heap-boxed
struct **named local passed BY BORROW** too. A borrow does not nil the local's slot, so the shell was freed
here AND again by the local's scope-exit `OP_DROP` — a double-free that corrupted the object list / pool and
aborted in `free_list` at program exit (it crashed the Claude-desktop app on close).

**Rule.** Exploding a struct argument is move-vs-borrow sensitive. Codegen keys on the same `moves_local`
flag it already uses to nil moved-out slots: a borrowed named local (`EXPR_IDENT && moves_local != 1`) is
exploded with the new **`OP_UNBOX_STRUCT_BORROW`** — it RETAINS each heap leaf (the source local keeps
ownership; the callee's param releases its copy on its own scope exit) and does NOT reclaim the shell, so
the live local survives for its single scope-exit drop. A fresh temp or a moved-out local (slot nilled)
keeps the reclaiming `OP_UNBOX_STRUCT`. Net ownership is conserved: a borrow adds one ref (balanced by the
callee's release), a move transfers the existing ref (balanced by the reclaim).

**Diagnosis technique worth keeping** (these bugs are invisible to plain ASan because the object pool
recycles memory instead of `free()`-ing, so a use-after-free reads valid re-allocated memory): build with the
pool bypassed or with `__asan_poison_memory_region` on pooled slots to expose it, and add a *double-drop
detector* to `reclaim()` (stamp `refcount` with a sentinel after reclaiming; a second reclaim before reuse
prints both drop sites + aborts). That pinned this in minutes after a long blind hunt. See OFI-057/058 and
the related [[ember-arena-node-init]]-class uninitialised-field bug (`alloc_struct_array.borrowed`).


## Decision: a spawned task starts at SPAWN (parallel), not at the nursery's closing brace

**Context.** The parallel nursery (`-DEMBER_PARALLEL`) originally recorded each `spawn`ed fiber and launched
ALL of their OS threads at `OP_NURSERY_END`, joining there — pure fork-join. So a spawned task did **not**
run concurrently with the rest of the nursery body. That breaks the event-loop idiom we need for a responsive
GUI (and streaming): `nursery { spawn fetch(ch); loop { try_recv(ch) … } }` — the body polls a background
task that, under fork-join, hadn't started yet, so the poll loop spun forever (a self-inflicted deadlock,
found via the tape).

**Rule (parallel runtime only).** `OP_SPAWN` now `pthread_create`s the task's OS thread **immediately**, so
it runs concurrently with the body; `OP_NURSERY_END` seals the group and joins every thread. A per-nursery
heap `NurseryRun` (allocated at `OP_NURSERY_BEGIN`, freed at the join) holds the threads, the per-task
`WorkerArg`s the workers read for their whole life, and the shared deadlock-detector `Nursery`. Because
`total` now grows as tasks launch mid-body, deadlock is declared only once the nursery is **`sealed`** (the
body has reached the closing brace and can no longer unblock a parked task); `nursery_park` gates on `sealed`
and `OP_NURSERY_END` re-checks at seal time to catch a group that all parked before the seal. The **serial**
runtime stays cooperative fork-join (a single thread cannot run a task concurrently with the body), so the
poll-in-body idiom is a parallel-runtime feature — see the language.md concurrency note. Companion primitive:
**`OP_TRY_RECV`** (`try_recv`), a non-blocking channel poll returning `Some(v)`/`None`, so the body never
blocks. Verified by `tests/parallel/` (a poll loop that would TIME OUT under fork-join) and the unchanged
serial golden suite. The accepted edge: an event-loop nursery whose body never reaches its closing brace
never seals, so a deadlock among its tasks isn't reported — acceptable (the body is live, the group isn't
fully blocked).


## Decision: `Channel<T>` is a refcounted shareable type — reclaimed at the last drop, not at exit

**Context (was the open tail of OFI-009/018).** Channels were classified by the checker as a "shareable handle,
not a move type" (`intern_channel`), which meant **no ownership at all**: codegen emitted no scope-exit drop
for a channel local (a temporary counter proved `drop_value` was called *zero* times on a channel), so every
channel created leaked to the program-exit sweep (`free_list`). Harmless for a batch program; a real,
unbounded leak for a long-running event loop (the GUI app creates a channel per request) — worse in the
parallel build, where the un-destroyed `pthread_mutex` + two condvars ride along (~273 B vs ~80 B each).

**Rule.** A channel joins the **refcounted shareable family** (strings, closures, enums): `is_refcounted`
returns true for `Channel<T>`, so the existing ownership machinery handles it with no codegen changes —
`OP_INCREF` on an aliasing owning-store (incl. the `consume`→`moves_local==2` retain when a channel is passed
to `spawn`, so each spawned task holds its own counted reference), and a scope-exit `OP_DROP` for every owning
binding/param. `drop_value`'s `OBJ_CHANNEL` arm (shared by the VM and the native runtime) now `OBJ_RELEASE`s
and, at the last owner, (1) **drains** any undrained buffered values — `send` moves a value in with no retain,
so the buffer owns it — then (2) **home-gated** (a context's lock-free arena must not be touched cross-thread)
destroys the OS primitives, frees the buffer, NULLs it as a sentinel, and `reclaim()`s the shell. `free_list`
skips a channel whose `buffer == NULL` (already torn down), so the exit sweep never double-frees. Because the
shell is now pooled like every other object, **`alloc_channel`/`em_channel_new` were switched from raw
`malloc` to `pooled_alloc`** — `pooled_free` (via `reclaim`) dispatches on `size_class`, which only
`pooled_alloc` sets; reclaiming a raw-malloc'd channel would have read uninitialised `size_class` and corrupted
the pool. Refcounting (vs forcing move semantics) preserves the design's intent — the same channel may be
shared by several tasks — and is safe regardless of join-vs-drop ordering: a borrower can't free a channel a
peer still references, so there is no use-after-free window. Verified: channel-create loops go RSS-FLAT (was
5→57 MB at 200k), all channel scenarios (shared-by-N, returned, abandoned-buffered, cross-thread home reclaim)
are ASan + double-drop-detector clean, the 312 goldens + native differential stay green, and
`error_channel_deadlock` still detects. Regression: `tests/run/channel_refcount.em` (+ a cross-thread variant
in `tests/parallel/`).




## Decision: HiDPI/Retina rendering via raylib's HIGHDPI projection (no extra camera)

The graphics backend opens the window with `FLAG_WINDOW_HIGHDPI`. That alone makes raylib render into a
physical-resolution framebuffer (a 1100-pt window → a 2200-px buffer on a 2× panel) **and** set up a
projection that maps logical points onto it. `BeginScissorMode`, the mouse, and `GetScreenWidth/Height` are
DPI-scaled by raylib the same way on Apple. So the entire toolkit — and the UI tape — describes the UI in
**logical points** and raylib does the single logical→physical mapping: clips, hit-testing, and layout stay
consistent with **no per-call scaling**, and the command buffer stores logical coordinates so the tape an
LLM reads is resolution-independent. On a Retina panel text is therefore rasterised at true device pixels
rather than logical-size-then-OS-upscaled (the soft look of OFI-060).

`g_scale` is the **real framebuffer ratio** `GetRenderWidth() / GetScreenWidth()` (re-read each frame so
dragging between displays tracks live), used **only** to bake glyphs at their device-pixel size (next
decision) — not the monitor's `GetWindowScaleDPI()`, which can report 2.0 even when the actual backing is
1×, and not a render-time transform.

History (OFI-060, two-stage): the first cut additionally rendered the command list under a `Camera2D` whose
`zoom == g_scale`, *on top of* raylib's HIGHDPI projection — double-scaling the whole UI to 2× its intended
size on a real Retina MacBook. It went unnoticed because it was never eyeballed on Retina (both dev displays
were 1×, where the camera is the identity transform). The camera was removed; raylib's projection already
performs the one mapping needed. On a 1× display `g_scale == 1.0` and the whole path is the identity, so 1×
output is unchanged.

This is the resolution layer only. Glyph *quality* on a fixed-resolution (1×) display is a separate axis —
bounded by rasterisation-at-target-size, gamma-correct/stem-darkened blending, and hinting — addressed by the
FreeType text path below.




## Decision: text is rasterised by FreeType at the real device pixel size, not baked-and-scaled

The graphics backend renders all text with FreeType (opt-in graphics-build dependency via `pkg-config
freetype2`, extending the raylib exception above), replacing raylib's stb_truetype path. The motivation
is quality on a **fixed-resolution (1×) display**, where resolution can't hide a soft rasteriser: raylib's
`Font` bakes one atlas at a base size and *scales* it in `DrawTextEx`, which discards hinting the moment the
drawn size differs from the bake size, leaving small UI text muddy. FreeType with `FT_LOAD_TARGET_LIGHT`
(light autohinting — vertical grid-fitting only, smooth advances) snaps stems to the pixel grid.

Hinting only survives if the glyph is rasterised **at its final pixel size**, so the cache is keyed by
`(face, physical_px)` where `physical_px = round(logical_size × g_scale)`. Each entry is a raylib `Font`
built from FreeType-rendered glyphs (we hand 8-bit coverage bitmaps to `GenImageFontAtlas`, then reuse
raylib's `DrawTextEx`/`MeasureTextEx` for layout — only the rasteriser changed). raylib's HIGHDPI projection
maps logical→physical by `g_scale`, so the Font baked at `physical_px`, drawn at logical size (scaling by
`1/g_scale`), reaches the screen pixel-for-pixel on every display. The embedded Inter is loaded with
`FT_New_Memory_Face` (its static bytes outlive the face); disk faces via `FT_New_Face`. Atlases bake lazily
on first use of each size and are freed at `window_close`.

Coverage is **on-demand** (OFI-069): each size atlas seeds with printable ASCII (so the common path never
rebuilds) and grows lazily — the first draw/measure of a string containing a code point the face has but the
atlas lacks rasterises that glyph and rebuilds the atlas once (sorted code-point set, binary-searched;
steady state is a pure membership scan, so the fixed-atlas speed is kept). A code point the *face itself*
lacks (Inter has no U+2715, CJK, emoji…) is left out so raylib draws its `?` rather than a `.notdef` box.
Both `draw_text` and `measure_text` route through this, so layout and rendering stay in lockstep.

Consequence: this is the rasteriser swap; glyph *metrics* now come from FreeType, which shifts measured text
widths slightly from stb — the graphics goldens (`tests/graphics/*.out`) were re-blessed accordingly. LCD
subpixel AA — the further quality step on a 1× RGB panel — is not yet wired; it needs a custom per-channel
text blit (raylib's tint path is single-channel), tracked as the next campaign step.




## Decision: Crucible — a generative memory-ownership fuzzer, separate from the `--check` logic fuzzer

Ember has two fuzzers, by design, because memory correctness and logic correctness are different
problems. The `--check` fuzzer (§5j) generates *inputs* to a contract-bearing function to find a
`requires`/`ensures` violation — it is a LOGIC oracle, and it deliberately restricts itself to free,
non-generic functions with all-scalar params. **Crucible** (tools/crucible.{c,sh}, run by `make
crucible`) is the MEMORY oracle: it generates whole *programs* in the ownership danger zone —
value-structs (flat / heap-field / nested) placed into erased-generic aggregates (`[T]`,
`Map<string,T>`, `Option<T>`, nested), passed by move and borrow, returned, read back, mutated through
an array index, interpolated, in loops — and runs each through five detectors we already had but used
by hand: the `-DEMBER_DROP_TRACE` double-drop detector, ASan, an RSS leak check, the VM↔native
differential, and a runtime-fault check.

Why a separate generative tool rather than more hand-written tests: the recurring memory bugs
(OFI-057/058/059/061/062) all lived at *cross-feature combinations* no one thinks to write a test for,
and were found reactively when a real program (Flare) tripped them. A seeded generator over the
combination space, with automatic dedup + shrink-to-minimal-repro and a baseline file
(`tools/crucible-known.txt`) so it fails only on a NEW signature, turns those reactive detectors into a
proactive CI gate. The generated programs fold every value they touch into a printed checksum, so the
differential catches silent wrong-answer divergences, not just crashes. It found OFI-063 (and re-found
the OFI-062 native crater) within minutes of first running. This is the verification-moat extended from
logic to memory: the language proves its own memory safety instead of us discovering holes by crashing.


## Decision: narrow bytecode operands — widen what a single function scales, guard the rest, gate the class

A recurring bug class (OFI-007, OFI-047, OFI-056) is a bytecode operand or pool/table index too NARROW
to hold a value past 255: a one-byte field silently wraps mod 256 and the VM loads the WRONG constant /
calls the WRONG function / builds the WRONG type — a miscompile, not a clean error. Each was found
reactively after it shipped. The response has two halves: a per-case policy and a class-wide gate.

Policy — widen vs guard, decided by whether ONE function legitimately needs the headroom:
- **Widen** a pool that a single large function genuinely overflows. A function's CONSTANT and STRING
  pools are per-function, and a big render function easily holds >256 literals (OFI-056). So `OP_CONST`
  / `OP_STRING` gained 3-byte-index siblings `OP_CONST_LONG` / `OP_STRING_LONG`, emitted ONLY past index
  255 (shared `emit_pool_op` in codegen). The common case stays one byte, so no existing bytecode or
  golden snapshot shifts — widening is opt-in per instruction, not a blanket operand-table change.
- **Guard** a whole-program id space, where the ceiling is rarely reached and a 16-bit operand would
  bloat every call site for headroom few programs need. Struct/enum/closure ids keep their one-byte
  operand + a clean "too many …" compile error (emit_u8_id, OFI-047). The function-table index is the
  exception that was widened to 16-bit (OFI-007) because functions+methods commonly exceed 256 — though
  note the checker's `MAX_FNS` array still caps function COUNT at 256, so that is the binding limit until
  a program needs more.

Class-wide gate — `tools/ceilings.sh` (`make ceilings`), the sibling of Crucible. Crucible fuzzes memory
ownership; ceilings fuzzes the narrow-operand class. For every compiler dimension (constants, strings,
locals, functions, struct types, fields, variants) it generates a program that pushes that dimension
PAST the 256 boundary and folds the touched values into a printed checksum, then asserts the only two
safe outcomes: WORKS (compiles, runs the right checksum, VM == native) or CAPPED (a clean compile
error). A crash, a wrong checksum (the silent wrap), or a VM≠native divergence is a failure. A baseline
(`tools/ceilings-known.txt`) records each dimension's expected outcome so the run fails on drift — a
WORKS that regressed to a wrap, or a CAPPED that started crashing. On first run it found two more
silent-truncation diagnostics (structs >64 fields, enums >64 variants dropped the overflow and surfaced
a misleading "no such field" / "undefined variable"); both now emit an honest cap. The principle: a
narrow operand may impose a limit, but it must never miscompile — and a tool, not a future crash,
enforces that.


## Decision: one operand spec + a shared codec + the opcheck gate (end operand mirror drift)

Each opcode's operand layout used to be hand-written in four places that had to agree: opcode.h (the
declared width), codegen (writes the bytes), the VM (reads them and advances ip), the disassembler
(re-reads). They drifted — a one-byte field declared correctly but a handler reading the wrong width
desyncs the VM far from the cause. OFI-007/047/056 were all this class, found reactively.

The fix makes the four mirrors derive from ONE source. include/opcode.h's X-macro now declares each
opcode's operand KINDS (`X(OP_CALL,"CALL",OPS2(U16,U8))`) rather than a byte count; a shared inline
codec (operand_read / operand_write / operand_width, keyed by OperandKind) is the single encode/decode
every consumer uses, so encoder ↔ decoder ↔ disassembler agree by construction. `make opcheck`
(tools/opcheck.{c,sh}) is the gate: (1) a codec round-trip proves encode∘decode is the identity for
every kind/opcode and that opcode_operand_bytes matches the codec; (2) a -DEMBER_OPCHECK VM build
asserts, over the whole corpus, that each handler consumed exactly the operand bytes its spec declares
— so a handler reading the wrong width aborts pinpointed instead of desyncing downstream. It is proven
with teeth: injected codec drift fails (1), injected handler drift aborts (2). The scaffold reproduces
today's exact widths, so it landed with the golden bytecode unchanged (the suite passing is the proof
the spec faithfully mirrors the real instruction set). This is the third standing gate, alongside
Crucible (memory ownership) and Ceilings (limit ceilings); together they turn the three recurring bug
classes into build/test-time failures. It is also the enabler for variable-width (LEB128) operands:
flipping a kind to LEB128 converts every opcode that uses it at once, verified by the gate, instead of
hand-mirroring the change across four files.

**Update 2026-06-18 — the LEB128 conversion is the standing policy now (supersedes "widen vs guard" above).**
Every index/slot/id/count operand is the `OPK_IDX` kind: **unsigned LEB128**, one byte for values < 128 and
unbounded above — it cannot overflow, so the narrow-operand miscompile class is structurally gone, not just
guarded. Consequences, all gate-verified (`opcheck` + `ceilings` + `crucible` + the 321-test suite):
- The OFI-056 stop-gap opcodes `OP_CONST_LONG`/`OP_STRING_LONG` and the per-emit overflow guards
  (`emit_fn_index`'s 16-bit cap, `emit_u8_id`'s one-byte cap, the `midx>255` / array-`count>255` checks) are
  **retired** — `emit_fn_index`/`emit_u8_id` now just delegate to `emit_idx`. The "widen vs guard" policy
  paragraph above is historical: there is no per-operand ceiling left to decide about.
- Variable-width operands mean a handler cannot rewind by a hard-coded byte count: the serial `OP_RECV`
  blocking retry now restores the saved opcode position instead of `ip -= 4`. Jump offsets stay fixed
  `OPK_OFF16` (back-patched — width must be known before the target).
- The operand conversion lifted the *bytecode* ceiling; the *binding* limit was the compiler's fixed `MAX_*`
  tables. Those are now ALL dynamic, so every `ceilings` dimension is `WORKS` (verified to N=2000): the checker's
  `locals`/`fns`/`structs` vectors, `StructInfo.fields`, and `EnumInfo.variants` grow on demand via one
  `grow_arena_vec` arena primitive; codegen's `local_*` arrays realloc-grow; the runtime value layout
  (`StructType`/`StructLayout`, program.h) and the native backend (`cgen_c.c`) carry pointer-sized per-field
  layout (offset/kind/field_struct) so there is no `EMBER_MAX_FIELDS`; the native scope table (`CGC_MAX_SCOPE`)
  is realloc-grown. The cached-`StructInfo*` realloc hazard is structurally avoided: `c->structs` grows only in
  pass 1a (name registration) before any long-lived pointer exists, and monomorphized instances live in
  `StructLayout`, not `c->structs`. Caps that remain are deliberate guards on OTHER spaces (top-level globals,
  enum/interface/generic-instance/array-type counts, params, methods) — clean errors, never silent wraps. The
  whole OFI-007/047/056 narrow-operand class is CLOSED (see OFI.md).


## Decision: networking is opt-in libcurl behind `std/http`, with STREAMING via a pull `Ptr` handle

*Decided 2026-06-19. Full design: [docs/http-design.md](http-design.md).* Ember binds **one** opt-in C
library for networking — libcurl, linked only by `make net`/`net-graphics` (off the default `make`/`make
test` path), the same blessed-single-dependency rule as raylib (§3.5, §5g). It is never named in Ember
code; user code sees only `import "std/http"`.

The hard constraint this resolves: **the `extern` ABI is context-free** (`int (*)(const Value*, Value*)`,
no `EmberRt`, no channel — by design, externs are pure C leaves), so an extern *cannot* push streamed
chunks into an Ember channel. Two ways out: (a) a runtime-aware *native* whose libcurl write-callback
calls `em_channel_send`; (b) a **pull** model — `curl_multi` behind an opaque `Ptr` handle, `http_open ->
Ptr`, `http_next(h) -> string` (next chunk, `""` at EOF), `http_close(move h)`, with the **Ember worker
fiber** owning the channel and doing the `send`s. **We chose (b).** It needs zero runtime/checker changes
(it's the `fopen`/`fread`/`fclose` `Ptr` leaf-FFI pattern, §5h; `Ptr` is linear per OFI-049, borrowed
in the `http_next` loop, `move`-consumed at close — the must-close half now also guarantees the worker
fiber can't forget `http_close`), it keeps concurrency 100% Ember (fibers + channels —
more on-thesis), and the blocking lives in `http_next` on a worker fiber exactly as `http_post` blocks
today. The push-native (a) is reserved for the future `curl_multi`-on-the-scheduler reactor (one thread,
thousands of connections), where callbacks no longer run on the caller's thread. The four streaming
externs live in `src/cextern.c` under `#if EMBER_NET`; verified end-to-end against a live HTTPS endpoint.
HTTP status is a `Response` field, not an error (`send` fails only on transport); `std/sse` and `std/json`
are separate modules. The capability model (`Net` token) is adopted as the NEXT language milestone, not
smuggled in here.

**Realized 2026-06-20.** The `std/http.em` wrapper module now actually exists, closing the gap between
this decision's "user code sees only `import "std/http"`" and the reality that the desktop app had been
declaring the four streaming externs (plus blocking `http_post`) in an inline `extern "c"` block. The
module wraps them as clean names — `http.post` (blocking, whole body) and `http.open`/`next`/`status`/
`close` (the streaming pull) — and is imported by `chat.em`, by the new reusable `anthropic` client
(which owns `stream_worker`), and is provable end-to-end against a live endpoint. Lifting the spawnable
`stream_worker` into that library module is what surfaced and closed OFI-091 (qualified-callee `spawn`).


## Decision: `spawn` accepts a module-qualified callee (`spawn mod.fn(args)`), like every other call

*Decided 2026-06-20 (OFI-091).* `spawn` once required a **bare-identifier** callee: the checker's
`STMT_SPAWN` validation resolved the function only when `call.callee->kind == EXPR_IDENT`, so a
module-qualified target — `spawn api.stream_worker(...)` — was rejected as "not a named function". An
arbitrary inconsistency: a qualified DIRECT call works everywhere, and qualified calls already cache
their resolved function on the AST node. It also directly blocked the on-thesis pattern of a *library*
exporting a spawnable fiber (the point of lifting `stream_worker` into `anthropic`/`std/http`). The fix
is **checker-only**: the spawn validation now also recognises the `EXPR_GET` / non-local-alias shape and
resolves it with `resolve_qualified_fn` (the same helper the direct-call path uses) for its
named-function + not-extern guards. `check_expr` then performs the normal qualified-call resolution,
caching `resolved_fn`/witnesses/arg-layout on the node — which **both** backends already read unchanged
(`codegen.c`'s `OP_SPAWN` and `cgen_c.c`'s `emit_spawn` key off `resolved_fn`, never the callee kind). No
backend change, ~12 lines. VM==native verified; regression `tests/run/spawn_qualified.em`.


## Decision: `Ptr` linearity (must-close) is a checker-only AND-merge dataflow, not a destructor

*Decided 2026-06-19. Full design + adversarial review: [docs/design/ptr-linearity.md](design/ptr-linearity.md). Closes OFI-049's leak half.*

The double-close half of OFI-049 (2026-06-18) made `Ptr` **move-only** (affine — used at most once) and
deliberately gave it **no scope-exit destructor** (Ember can't know whether an arbitrary C handle is
freed by `fclose`/`free`/`sqlite3_close`). The leak half — a handle never closed — needed the dual
guarantee: **used at least once**. Two ways out were on the table: (a) destructor-carrying *typed*
handles (`Handle<Tag>` with an associated closer, Rust `Drop`-style, auto-close at scope end); (b)
**linear types** — force an explicit consume on every path, purely in the checker. **We chose (b).** (a)
relitigates the deliberate no-destructor decision, needs a per-handle closer (one opaque `Ptr` type
can't carry one) → typed handles across all backends, and silent auto-close of a C handle can surprise.
(b) is **checker-only** (`src/check.c`) — both backends already honour `moves_local`/scope-drop, so a
compile-time proof covers VM and native with **zero runtime cost** and no codegen/VM/runtime edits, the
same leverage the double-close half used.

The mechanism is the affine move analysis **inverted**. The checker already tracks `moved` with an
**OR-merge** at control-flow joins ("moved on *some* path" — sound for use-after-move). Linearity needs
the **AND-merge dual** `consumed` ("consumed on *every* path"), maintained side-by-side with `moved` at
every join (mirror-drift discipline, like opcheck) and inverting OR→AND while reproducing the four-way
divergence handling. A shared, decl-independent `report_unconsumed_ptrs` scans for an owned un-consumed
`Ptr` at every exit (`return`, `break`, `continue`, `?`, a discarded statement temp, `var` reassignment,
and folded into `drop_locals` for fall-through). Three subtleties the design's adversarial review (a
5-agent workflow) surfaced and that drove the final shape: **(1)** the guards must live at **type
formation**, not value sites — a generic body is checked once with its parameter abstract, never at
`T = Ptr`, and `is_refcounted(TY_PTR)` is false so `Map<_,Ptr>.set` never calls `consume`; so `Ptr` is
barred as an array/field/enum/channel element or generic argument (with a defensive `TY_ERROR` floor in
the intern functions). **(2)** an infinite `loop` exits only via `break`, so an outer handle's
post-loop `consumed` state is the AND over the break paths — without this the textbook close-on-break
read loop is a false "leak". **(3)** a `Checker.unreachable` flag stops a leak being reported on
statically-dead code (a trailing `return` after an exhaustively-diverging `if`) — a general
diagnostic-correctness win beyond linearity.

Enforcement is a **hard error**, symmetric with the double-close half — a leak warning the LLM ignores
closes nothing, and the compiler is the LLM's verification loop. The one residual friction (the
N-handle error-cleanup fan-out) wants a `defer`/`with` scoped-close, **deferred** to a future widening
since the corpus has zero multi-handle FFI code (the null-safe single-close idiom covers today). A new
generative fuzzer, **Ledger** (`tools/ledger.{c,sh}`, `make ledger`), is Crucible's compile-time
sibling: it generates `Ptr`-lifetime programs (if/else+match trees, close-on-break loops, reassignment
chains) with a known accept/reject oracle and asserts the compiler's verdict matches — catching both a
leak that compiles and a balanced program rejected. It found the reachability false positive (3) above.
Ledger joins `make verify`. The pre-existing loop-body move-check over-conservatism it also surfaced is
logged as OFI-074 (over-strict, not unsound).




## Decision: the splitter resize control — an absolute-anchor drag latch + a tape-silent `set_cursor` builtin

*Decided 2026-06-20. Closes OFI-085. Designed via a 3-spec judge-panel workflow; the implementation was then
adversarially reviewed (5 dimensions → per-finding verify), which drove the modal-latch and orientation fixes below.*

A draggable resize/split control (`std/flare.splitter`, engine `std/ui._split_drag`) needed three design calls.

**(1) Absolute-anchor drag math, not grab-offset.** The window title-bar drag stores a grab offset and each
frame sets `pos = mouse - offset`. A splitter can't copy that: its handle leaf is laid out *after* the resized
pane, so the handle's own solved `x` *moves under the cursor* as the pane grows — a formula reading the live
handle position drifts. Instead, at the press we capture `sp_base = size` and `sp_grab = mouse-axis`; each held
frame `size = sp_base + (mouse-axis − sp_grab) · sign`, clamped. This is independent of the handle's position
and works for any pane location and both axes. The handle's last-frame rect is used *only* for the over-hit-test.

**(2) A dedicated, independent latch — released defensively.** `sp_drag`/`sp_grab`/`sp_base` are separate from
the window (`drag_id`) and scrollbar (`sc_drag`) latches, so the three can't desync (the same "make the bad state
unrepresentable" principle as the per-window registry). Unlike those, a splitter's release sits behind Flare's
modal-inert gate, so a modal opening mid-drag would orphan the latch and snap the pane on the next press; the
fix is `ui.split_release(id)`, which the gated branch of `f.splitter` calls so a held latch is dropped while
inert (rather than a global mouse-up clear in `begin()`, which would fight the goldens' injected-input pattern).

**(3) `set_cursor` is a VM-only, tape-silent graphics builtin.** A real splitter shows a ↔/↕ resize pointer.
`set_cursor(shape)` (Ember-abstract shapes 0–4 mapped to raylib `MOUSE_CURSOR_*` in `graphics.c`, so Ember never
leaks raylib's enum) mutates OS state directly with **no `gfx_push_cmd`** — exactly like `set_layer` — so it
emits no draw command and cannot perturb a render golden. `frame_begin` resets the cursor to default each frame,
so a widget only re-asserts its shape while hovered; nothing has to "unset" it. It is VM-only (the graphics
backend runs on the VM; `cgen_c` has no graphics dispatch), wired through `builtin.h`/`builtin.c`/`check.c`/
`vm.c`/`graphics.{h,c}` like every other gfx builtin and guarded by `#if EMBER_GRAPHICS` so the default build is
untouched. Verified tape-silent (graphics goldens unchanged after the builtin + the per-frame reset landed).

The control is per-block-orientation-tagged in its paint node (`"v"`/`"h"` in the otherwise-unused text slot) so
the painted hairline matches the drag axis by construction at any rect, and its `before` flag generalises to a
pane on either side of the handle (both branches test-covered in `tests/graphics/splitter.em`). The app wiring
(`flare_chat.em` sidebar) made the sidebar width a persisted `state_int` the splitter drives, and the max is
window-aware so a wide sidebar can't squeeze the transcript off a narrow window.




## Decision: Flare animation is springs over a FIXED timestep — deterministic, not wall-clock

*Decided 2026-06-21.* Flare gained animation — spring physics + FLIP layout transitions — on the keyed-state
surface (the highest-leverage item from the "next-level" research, Tier-4). The load-bearing choice: each
spring advances by a FIXED per-frame step (`SPRING_DT` ≈ 1/60), NOT a `clock()`-derived real delta. So the UI
stays a pure function of (state, FRAME COUNT) — deterministic, replayable, golden-testable (the regression
goldens `flare_spring`/`flare_flip` are exact curves) — instead of importing `clock()`'s nondeterminism into
the render path (a quiet erosion of the verification/determinism thesis the research flagged). The cost is
frame-rate-dependent wall time: sustained below 60fps, animations run proportionally slow. Acceptable because
the raylib backend targets 60fps vsync, and determinism > wall-clock fidelity for an LLM-first, replay-driven
language. Revisitable: a real-dt mode could be opt-in later (clamped, tape-recorded) without an API change.

Mechanism: (1) springs are semi-implicit Euler over a `(pos,vel)` pair in a new float-state column `sf`,
default preset ~critically damped (stiffness 170, damping 26), with a rest threshold that snaps-and-stops so a
settled spring stops churning state; (2) `f.at(dx,dy)` is a pure PAINT-QUEUE bracket (no layout node) —
`finish()` accumulates a `(dx,dy)` offset over a nesting stack and adds it to the painted rect, generalizing
the scroll viewport's existing y-shift to both axes; (3) FLIP (`animate_layout`) is the standout — Flare
already caches every widget's last-frame solved rect, so `_flip_axis` springs the per-frame solved-position
JUMP toward zero at paint time, never feeding back into the solve. No web framework gets FLIP this cheaply;
it falls out of "re-solve real flexbox every frame + keep last frame's rects" — Flare's structural advantage.


## Decision: the M:N green-thread scheduler is cooperative fibers on a worker pool — the VM IS the yield point

*Decided 2026-06-20. Closes the deferred half of OFI-071. Designed via a 5-agent adversarial design-hardening
workflow (one expert per failure mode → synthesized spec); built + verified TSan/ASan/stress. Gated behind a new
`EMBER_MN` flag; the proven 1:1 thread-per-spawn runtime stays the default `make parallel` until a wider soak.*

Ember's concurrency model (founding principle #4) is Go-goroutine ergonomics: spawn *thousands* of cheap tasks,
no function colouring. The 1:1 build (`-DEMBER_PARALLEL`) ran one OS thread per `spawn` — correct and ~5–6× on
compute, but it can't carry thousands of fibers (one pthread each). The endgame (an OS kernel in Ember) needs a
real scheduler regardless. So we built M:N.

**The key realization — no stackful context switch.** The scary version of M:N is `ucontext`/hand-written arm64
register save-restore. We don't need it: the VM bytecode interpreter is *already* the cooperative yield point. A
channel op that must block sets `block_channel` and `return VM_YIELD`, and a fiber's entire state lives in its
`Fiber` struct (`stack[]` + `frames[]`). The serial scheduler was already a green-thread round-robin. So M:N is
"run that cooperative scheduler on M worker threads sharing a ready-queue, *parking* fibers on channels instead of
blocking the OS thread." This made a feared multi-week effort tractable, reusing the thread-safe heap (atomic
refcounts, per-context arenas, cross-thread-free deferral) the 1:1 work already built.

**Five load-bearing decisions** (each from a failure-mode analysis):
1. **Arena follows the fiber.** `EmberRt` moved from the worker VM into the `Fiber`. A migrated fiber keeps one
   `home` regardless of which worker runs it, so cross-worker frees stay home-gated and the leak closes
   *structurally* — strictly better than worker-affinity (which only masks it).
2. **One `fstate` atomic arbitrates every transition.** READY/RUNNING/PARKED/DONE; every move is a CAS, so a
   channel-wake and a cancel-sweep racing for the same parked fiber enqueue it *exactly once*.
3. **Lost-wakeup-free channel park.** The blocked op observes emptiness, registers on the channel's intrusive
   fiber FIFO, and commits to yield — all under one `ch->lock`. A waker only empties the FIFO under that same
   lock, so it can't miss a parker; a parker re-observes under the lock, so it can't park a ready channel.
4. **The parent owns the nursery.** `live` is guarded by `n->lock` (not a bare atomic); the parent's seal-time
   live-read and a child's decrement serialize, so exactly one of {parent parks then is woken} / {parent sees
   live==0 and finalizes} happens, and the parent — never a child — frees the group and its children. Children
   are freed at finalize (after `live==0`), so the structured-cancellation sweep can never touch freed memory.
5. **Global deadlock, global lock order.** Deadlock is now a scheduler property: all workers idle + ready-queue
   empty + a live fiber remains. The single total lock order `channel > nursery > readyqueue > heap` is acyclic
   (proven in the design); the worker releases the ready-queue lock before running a fiber, so no `readyqueue →
   channel` back-edge ever forms.

**Scope & gating.** M:N is **VM-only** (the canonical runtime; `--emit=run` runs the dogfood apps). The native
AST→C backend keeps the 1:1 model (`runtime.c`'s native concurrency is `#if EMBER_PARALLEL && !EMBER_MN`). M:N is
gated behind `EMBER_MN` (which implies `EMBER_PARALLEL`); the default builds are untouched. **First cut keeps it
simple:** one global mutex+condvar ready-queue (delivers "thousands of cheap fibers"); work-stealing deques are
deferred (OFI-087 — they need distributed termination detection to preserve the no-false-negative deadlock
guarantee). A `Fiber` still embeds a full value stack (~64KB), so the literal 100k-fiber tier awaits segmented
stacks (OFI-088); thousands work today. **Verification (the gate to flip the default):** `make tsan-mn` (race
detector, clean), `make asan-mn` (UAF, clean), `tools/mn-stress.sh`/`make mn-stress` (the new concurrency fuzzer:
8000-fiber headline, fan-in/out, nested nurseries, deadlock, cancel, pipeline — all watchdog-guarded), and a
byte-for-byte differential against the serial runtime over the run-stage suite.

## Decision: `rc struct` is a per-TYPE flag + a per-step mutation walk — boxed like an enum, immutable by formation

`rc struct` (shared, immutable, reference-counted user structs — the manifesto's "blessed Rc") is
implemented so it rides the EXISTING shareable machinery rather than adding a parallel one. Key choices:

- **`is_rc` lives on the TYPE, not the instance.** It is one flag threaded `StructInfo → StructLayout →
  StructType` (and read by the native backend's `is_value_struct`). The shared runtime (`drop_value`,
  `own_into_slot`) reads `ctx->structs[type_id].is_rc`, so BOTH backends get correct behaviour with no
  `ObjStruct`/`alloc_instance` change — an rc value is just a boxed, refcounted `ObjStruct` (refcount
  already inits to 1), reclaimed at the last owner via the StructType descriptor's boxed-field loop,
  exactly like an enum but with PACKED (not all-16-byte) fields. Chosen over a distinct `ObjStruct.is_enum`
  sibling because the rc-ness is a property of the type, and every reclamation/ownership site already has
  the `type_id` in hand. (Watch-out found in the process: the native backend emits a POSITIONAL
  `StructType` initializer, so adding the `is_rc` field silently misaligned it — fixed, filed as an OFI.)

- **The classifier flips do the routing.** `is_move_type(rc)=0` + `is_refcounted(rc)=1` move an rc value
  onto the existing incref/alias path in `consume()` (the same one strings/enums take), so `let b = a`
  increfs with no new code. Six layout predicates (`nested_inline_sid`, `struct_all_scalar_id`,
  `array_inline_struct_id`, …) bail to "boxed" for rc, so it is never inlined/value-typed/multi-slot —
  no INCREF-then-unbox-free drift.

- **Deep immutability is enforced two ways.** Formation: a closed positive whitelist
  (`is_immutably_shareable`) at the field site — a field must be scalar/string/enum (generic enums only
  if every concrete arg recurses-shareable)/another rc struct; arrays, plain structs, `Ptr`, fn/closure,
  channels, interfaces, and bare type-params are refused. Mutation: a **per-step path-walk** at every
  assignment target — the pre-existing gate checked only the ROOT binding's `var`-ness, which an
  adversarial design pass showed is insufficient (a `var` non-rc wrapper holding an rc field would launder
  `w.r.x = v` into a shared interior), so the gate now rejects a write THROUGH any rc step, however reached.
  These two, plus eager bottom-up construction, make a reference cycle unconstructable — preserving
  refcount completeness.

- **Generic `rc struct<T>` is deferred (v1).** A type-param field is erased at the declaration, so deep
  immutability can't be decided there without net-new use-site bound machinery for zero current callers.
  Rejected at the decl; non-generic rc is the complete, sound feature.

- **`rc` is a CONTEXTUAL keyword, not reserved** — lexed as an identifier, special only immediately before
  `struct` (`rc struct …`). `rc` is a very common identifier ("return code"); reserving it would break code.

**Verification:** the soundness was designed via a 14-agent adversarial workflow (all 8 smuggle vectors
reduced to these rules); each vector has a reject test, the accept path has run + native-differential
golden tests, and Crucible gained an **rc seed mode** (a quarter of its seeds declare `rc struct`s and
churn them through the aggregate/leak/diff/double-drop oracles) — 187 seeds clean.
