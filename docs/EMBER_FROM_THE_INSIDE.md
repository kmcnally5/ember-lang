---
title: Ember from the Inside
nav_order: 10
permalink: /inside
description: Ember from the Inside — how the language is designed, parsed, checked, and run. A guided tour of the compiler, with the source code as the star.
---

# Ember from the Inside

### How the language is designed, parsed, checked, and run — for the curious of every stripe

*Covering the compiler as it stands on 1 July 2026. A companion to
[Ember by Firelight](THE_EMBER_BOOK.md), which teaches you to **write** Ember; this book shows you
what happens to what you wrote.*

---

> **The one promise this book makes**
>
> A book about a compiler can cheat in a way a language tutorial can't: it can describe machinery
> that isn't really there, quote code that was "tidied up" for print, or show output nobody ever
> ran. This book does none of those things, and here is precisely what that means:
>
> - Every **C excerpt** is copied byte-for-byte from the file it names, from the tree this book
>   ships in. Nothing was abridged mid-line, renamed, or prettified.
> - Every **compiler output** shown is one of the repository's own **golden files** — the recorded
>   outputs under `tests/` that `make test` compares against on every run. If a golden in this book
>   ever drifts from the compiler, the test suite fails before the book does.
> - Every **Ember sample** is copied from a file in
>   [`tests/`](https://github.com/kmcnally5/ember-lang/blob/main/tests) or
>   [`examples/`](https://github.com/kmcnally5/ember-lang/blob/main/examples) that the suite
>   compiles. This book invents no samples of its own.
>
> Ember moves quickly, so treat this as a photograph with a date on the back. The live ledger of
> what has changed since — every bug, flaw, and improvement, numbered and dated — is the
> [OFI log](OFI.md), which Chapter 18 will argue is one of the more interesting files in the repo.

---

## How to read this book

Three kinds of reader tend to open a book like this, and all three are welcome.

If you are **curious but not a compiler person**, read the prose and the boxes and step over the
code. Every chapter explains its subject in ordinary words before any C appears, and each ends the
technical stretch with a **In plain terms** box that says the same thing again without the jargon.
You will leave knowing how a programming language actually gets made, which is a genuinely
pleasant thing to know.

If you **write software but have never read a compiler**, this book is designed to be your first
one. Ember's compiler is unusually readable as these things go — hand-written C, no generated
parser tables, no framework — and every excerpt cites its exact file so you can open the real
thing beside the page.

If you **build compilers for a living**, skip straight to the bespoke bits: the X-macro vocabulary
(Chapter 4), the LEB128 operand story (Chapter 9), the measured dispatch decision (Chapter 10),
the differential native backend (Chapter 11), the Fourier–Motzkin prover (Chapter 13), and the
standing fuzzer gates (Chapter 14). Chapters 17 and 18 cover the self-hosting effort and the
engineering culture, which is where this project is least like the textbooks.

A few conventions:

- C excerpts name their file just above the fence, and look like this:

  ```c
  // (an excerpt from the compiler's own source would appear here)
  ```

- Compiler output quoted from a golden file names that file, and looks like this:

  ```
  => 0
  ```

- The two recurring boxes: **In plain terms** re-explains the chapter's machinery without jargon,
  and **Machine-room trivia** wanders off to look at something faintly ridiculous and true, in the
  proud tradition of Firelight's *Fireside trivia*.

---

# Index

**Part I — The Idea**
- [Chapter 1 — Why Build a Language in 2026?](#chapter-1--why-build-a-language-in-2026)
- [Chapter 2 — Two Products, One Repo](#chapter-2--two-products-one-repo)

**Part II — The Journey of a Program**
- [Chapter 3 — The Journey of a Program](#chapter-3--the-journey-of-a-program)
- [Chapter 4 — Words: The Lexer](#chapter-4--words-the-lexer)
- [Chapter 5 — Shape: The Parser](#chapter-5--shape-the-parser)
- [Chapter 6 — The Tree and the Arena](#chapter-6--the-tree-and-the-arena)
- [Chapter 7 — Meaning: The Checker](#chapter-7--meaning-the-checker)
- [Chapter 8 — When Things Go Wrong](#chapter-8--when-things-go-wrong)

**Part III — Running It**
- [Chapter 9 — Lowering: Bytecode](#chapter-9--lowering-bytecode)
- [Chapter 10 — The Machine: The VM](#chapter-10--the-machine-the-vm)
- [Chapter 11 — The Second Road: Native Code](#chapter-11--the-second-road-native-code)

**Part IV — The Truth Machinery**
- [Chapter 12 — The Tape](#chapter-12--the-tape)
- [Chapter 13 — Contracts and the Little Prover](#chapter-13--contracts-and-the-little-prover)
- [Chapter 14 — The Gates](#chapter-14--the-gates)
- [Chapter 15 — One Frontend, Many Faces](#chapter-15--one-frontend-many-faces)

**Part V — The Edges**
- [Chapter 16 — Talking to C](#chapter-16--talking-to-c)
- [Chapter 17 — The Compiler That Eats Itself](#chapter-17--the-compiler-that-eats-itself)
- [Chapter 18 — The OFI Ledger](#chapter-18--the-ofi-ledger)
- [Chapter 19 — A Reader's Guide to the Source](#chapter-19--a-readers-guide-to-the-source)

[Colophon](#colophon)

---

# Part I — The Idea

## Chapter 1 — Why Build a Language in 2026?

Every programming language is an argument. Before a single line of the compiler existed, Ember's
argument was written down in a document called the
[manifesto](https://github.com/kmcnally5/ember-lang/blob/main/MANIFESTO.md), and the project holds
itself to an unusual rule: **every language-design decision must trace back to a principle in that
document.** If a decision can't, either the decision is wrong or the manifesto gets amended — out
loud, deliberately, in writing. So the honest way to explain why Ember exists is to walk the
argument, not to advertise the product.

The argument starts with credit where it is due. By 2026 the systems-programming conversation has
three poles: **Rust**, which proved you can have memory safety without a garbage collector and
moved from hype to mandate on the strength of it; **Zig**, the radically simple, explicit
better-C; and **Go**, still the productivity champion for networked services, at the price of a
runtime. The manifesto's opening section is blunt about the first of these: Rust *won the
argument* about memory safety. Ownership-based lifetime management eliminates use-after-free,
double-free, and data races as a class, and Ember does not relitigate any of it. Sum types,
exhaustive pattern matching, errors as values, no null, immutability by default, a real toolchain
in the box — the manifesto lists these as settled questions, inherited with thanks.

The disagreement is about the road, not the destination. Rust's own community documents the cost:
new developers spend weeks to months fighting the borrow checker; async is famously "a second,
harder language"; compile times strain iteration; the surface area keeps growing. Ember's thesis,
in one sentence from the manifesto: **Rust proved the destination is right, but the road there is
harder than it needs to be.** Ember aims for Rust-grade compile-time safety with something much
closer to Go- or Zig-grade approachability and iteration speed. Whether it gets there is not a
claim this book will make for it — the point of the rest of these chapters is to show you the
machinery and let you judge.

Three of the manifesto's answers shape everything you will see in this book, so they are worth
meeting up front.

**Safety must be progressively disclosed.** A beginner should write correct, safe programs on day
one without learning lifetime theory. Ember keeps ownership — values move, borrows are the
default, mutation is opt-in — but there are no lifetime annotations to write, no `&`/`&mut`
sigils, and the common tree-shaped patterns need zero ceremony. Where data is genuinely
graph-shaped, the sanctioned tools are a generational
[`std/slotmap`](https://github.com/kmcnally5/ember-lang/blob/main/std/slotmap.em) and a
deeply-immutable `rc struct`, rather than an escalating fight with a borrow checker. The dangerous
direction — a move — is the one you must type.

**Concurrency belongs to the language.** One runtime, in the standard library; structured
`nursery`/`spawn` blocks; no async/sync function colouring; real stack traces. Chapter 10 shows
what that costs and buys at the virtual-machine level.

**The primary audience is a model that has never seen Ember.** This is the unusual one, and the
manifesto is candid that it is a bet. Coding is moving to AI, so Ember's syntax is chosen by a
"least surprise, for the model" rule: a zero-shot LLM predicts semantics from priors learned on
every other language, so each keyword is picked to mean what such a reader would guess it means.
`match`, not `switch`, because `switch` drags in fallthrough expectations that would be wrong.
`let`/`var`, `requires`/`ensures`, `extern "c"` — familiar spellings, familiar semantics. And
beyond syntax, the machinery of the whole toolchain — structured diagnostics, machine-readable
faults, an execution tape, executable contracts — exists so that a model (or a human) gets told
the truth about a program in a format it can act on. Chapters 8, 12, and 13 are that story.

> **In plain terms.** Ember's designers wrote down what they think the last decade of programming
> languages got right and wrong, and made themselves legally answerable to that document: no
> feature gets in unless the reasoning traces back to it. The three big commitments: be as safe as
> Rust without making you study for weeks first; make running things at the same time a normal
> part of the language; and design every surface so that a newcomer — human or AI — guessing what
> something means will guess right.

---

## Chapter 2 — Two Products, One Repo

The repository is home to two things the project is adamant about keeping separate: **the Ember
language** — grammar, semantics, the type system, the thing the manifesto governs — and **the
Ember compiler**, `emberc`, a batch program written in C that implements it. A change to one is
not automatically a change to the other, and each has its own constitution: the language answers
to the [manifesto](https://github.com/kmcnally5/ember-lang/blob/main/MANIFESTO.md), the compiler
and toolchain answer to [architecture.md](architecture.md), a living document of engineering
decisions, each recorded as a rule plus the reasoning. When you wonder "why is it like this?"
about anything in this book, one of those two documents almost always has a written answer — and
this book will keep citing them, because the paper trail is the point.

Why C, for the compiler? The reasons are recorded, not folkloric: speed; portability (macOS and
Linux, x86-64 and arm64, any C17 compiler); zero install-time dependencies; and total control over
memory layout and the runtime. The default build links the C standard library and **nothing
else** — no parser generator, no JSON library, no LLVM. Capabilities another project would pull
from a package are written in-tree: the JSON reader, the contract prover, the FFI registry, the
property fuzzer, the language server. When you build `emberc`, the dependency tree is empty, which
is a sentence that sounds dull until you have spent a week of your life debugging someone else's
transitive dependency. Three opt-in builds bend the rule deliberately — raylib for graphics,
libcurl for networking, a vendored SQLite for databases — and all three are kept firmly off the
default path, so `make` and `make test` run on a bare, headless machine.

Two habits of the project matter more than any single technical decision, because they explain the
texture of everything in Parts II–IV.

**The walking skeleton.** Ember's ancestor project (an earlier language called FROG) taught a
painful lesson: build the whole language as an interpreter and bolt a VM on later, and you get a
retrofit plus two backends drifting apart. So Ember grows the **entire pipeline end-to-end from a
trivial subset outward** — every feature is added through lexer, parser, checker, and code
generator in one slice, and it is not "done" until it executes and has a test. The front-end can
never get ahead of the backend, because there is no such place to be.

**Raise it, don't code around it.** When work in one corner uncovers a bug, a design flaw, or an
inconsistency with the manifesto anywhere else, the rule is to file it — numbered, dated, in
[OFI.md](OFI.md) ("Opportunity For Improvement") — rather than quietly working around it. Items
are never renumbered and never reused; closed items keep their post-mortems. The log is up past
OFI-168 at the time of writing, and reading it is the closest thing to sitting in the room while
the language was built. Chapter 18 gives it the tour it deserves.

One more piece of context you will feel throughout: the compiler is a **batch process**. It runs,
compiles, maybe executes your program, and exits. That lifecycle is why the memory strategy
(Chapter 6) is arenas rather than reference counting, why whole-program compilation is acceptable
for now, and why the code can afford to be simple in places a long-lived server could not.

> **In plain terms.** One repo, two artifacts: the language (a design, governed by a philosophy
> document) and the compiler (a C program, governed by an engineering log). The compiler is built
> the way you'd build a hand tool — no moving parts you didn't make yourself. New features must
> work end-to-end before they count as existing, and discovered problems get written down in a
> public ledger instead of patched over.

> **Machine-room trivia.** The project's coding rules are themselves versioned like code. The
> convention for blank lines between C functions — five in sparsely-commented files, two where
> every function carries a doc comment — was debated, decided, and recorded as OFI-144, so even
> the whitespace has a paper trail.

---

# Part II — The Journey of a Program

## Chapter 3 — The Journey of a Program

Everything the compiler does is a pipeline, and the manifesto states it in one line: **source →
tokens → AST → type-check → lower → bytecode → VM**. Since 2026-06 there is also a second exit
ramp after the type-check — a native backend that emits C — but the shape is the same. Drawn out,
with the file that owns each arrow:

```
  source text (.em)
      │   lexer      src/lexer.c     characters  → tokens
      ▼
  tokens
      │   parser     src/parser.c    tokens      → syntax tree (AST)
      ▼
  AST
      │   checker    src/check.c     names, types, ownership — annotates the tree
      ▼
  checked AST ────────────────────────────────┐
      │   codegen    src/codegen.c            │   cgen_c   src/cgen_c.c
      ▼                                       ▼
  bytecode                                 C source → system C compiler → native binary
      │   VM         src/vm.c
      ▼
  output, faults, and (if asked) the tape
```

The pleasant thing about `emberc` is that the pipeline is not sealed: nearly every stage has a
window you can open. The driver ([src/main.c](https://github.com/kmcnally5/ember-lang/blob/main/src/main.c))
documents them in its own `--help` text, which is worth quoting as it appears in the source:

```c
                "usage:\n"
                "  emberc <file.em>                inspect/compile a source file (default --emit=tokens)\n"
                "  emberc --emit=<mode> <file.em>  mode: run|ast|bytecode|c|docs|prove|check|replay|trace|tokens\n"
                "  emberc -o <bin> <file.em>       compile to a native binary (C backend)\n"
                "  emberc --tape <file.em>         record the execution tape (alias for --emit=trace)\n"
                "  emberc --lsp                    run the language server (JSON-RPC over stdio)\n"
                "  emberc --doctor                 check your setup and print the fix for anything wrong\n"
```

`--emit=tokens`, `--emit=ast`, and `--emit=bytecode` stop the pipeline early and print what that
stage produced — Chapters 4, 5, and 9 use them constantly. `--emit=run` goes all the way through
the VM. `--emit=c` and `-o` take the native road. The rest are the verification suite riding the
same frontend: `prove` (static contract proof), `check` (property fuzzing), `trace`/`--tape` (the
execution tape), `replay`, `docs`, and `--lsp`, the language server, which is the same binary
serving your editor. One frontend, many windows; most of Part IV is what lives behind the odd
ones.

Exit codes follow the BSD `sysexits` convention, per the comment above `main`: **64** you used the
compiler wrong, **65** the source had an error (lexing, parsing, type-checking, or a runtime
fault), **66** the file couldn't be read, **0** all was well.

Every journey needs a traveller. Here is ours — seven lines from the test suite,
[`tests/codegen/functions.em`](https://github.com/kmcnally5/ember-lang/blob/main/tests/codegen/functions.em),
chosen because the suite locks its output at two different stages, so you will see it again in
Chapter 9 compiled to bytecode, instruction by instruction:

```ember
// functions.em — locks multi-function bytecode and the OP_CALL instruction.
fn add(a: int, b: int) -> int {
    return a + b
}
fn main() -> int {
    return add(2, 3)
}
```

> **In plain terms.** The compiler is an assembly line: raw text is chopped into words, the words
> are arranged into a tree that captures the grammar, the tree is interrogated until every name
> and type is accounted for, and then the tree is translated into instructions a small virtual
> machine executes (or into C, for a standalone binary). The `--emit` flag is a set of inspection
> hatches, one per station.

> **Machine-room trivia.** Run `emberc hello.em` with no flags at all and you get… the token
> stream. The default `--emit` mode is `tokens` — a small archaeological trace of the walking
> skeleton: the lexer was the first station built, so printing tokens was once all the compiler
> could do, and the default has simply never needed to change.

---

## Chapter 4 — Words: The Lexer

Before a compiler can think about your program it has to read it, and it reads the way you were
taught to: letters into words. The lexer (or *scanner* — Ember's source uses both) turns a stream
of bytes into a stream of **tokens**: `let` is a token, `x` is a token, `=` and `42` are tokens.
No meaning yet, no grammar — just spelling. The whole thing is
[`src/lexer.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/lexer.c), 504 lines of
hand-written C: no regular expressions, no generated tables, a `switch` on the current character
and some look-ahead.

Here is what a token actually is, from
[`include/token.h`](https://github.com/kmcnally5/ember-lang/blob/main/include/token.h):

```c
// A Token is a zero-copy view into the source buffer: `start` points into the
// original text and `length` is the lexeme's byte count. The source buffer must
// therefore outlive every Token derived from it. `line`/`col` are 1-based and
// mark the lexeme's first character.
typedef struct {
    TokenType   type;
    const char *start;
    size_t      length;
    int         line;
    int         col;
    // A `///` doc-comment block immediately preceding this token, as a raw view
    // into the source (the `///` markers and inter-line newlines are still
    // present; a consumer strips them — see the parser's doc cleaner). NULL/0
    // when no doc comment precedes the token. Only the first token of a
    // declaration carries it; everything else leaves it NULL.
    const char *doc;
    size_t      doc_length;
} Token;
```

Two design choices are visible right in the struct. First, tokens are **zero-copy**: a token
doesn't own the text `42`, it points at those bytes where they already sit in the source buffer.
The lexer allocates nothing per token; text is copied exactly once, later, when the parser decides
a particular identifier is worth keeping (Chapter 6). Second, that odd `doc` field: Ember's `///`
doc comments are not thrown away as whitespace. The lexer gathers a run of consecutive `///` lines
and hangs the raw span on the next real token, and from there a single cleaned copy of your prose
travels the whole toolchain — the same bytes surface in your editor when you hover a function and
in the output of `emberc --emit=docs`. One corpus, two consumers, no drift. (Exactly three
slashes, mind: `//` is an ordinary comment and `////` is decoration, and the lexer counts.)

### The vocabulary lives in one file

How does the lexer know `let` is a keyword and `lettuce` is not? In most compilers the keyword
list lives wherever the lexer is, and a *second* copy lives in the editor's syntax highlighter,
and a *third* in the completion engine, and they rot apart quietly. Ember's answer is a single
file, [`include/vocab.def`](https://github.com/kmcnally5/ember-lang/blob/main/include/vocab.def),
which opens by stating its own job:

```c
// vocab.def — the single source of truth for Ember's lexical vocabulary.
//
// Keywords, builtins, and primitive types each appear here EXACTLY ONCE. Every consumer
// (the lexer's keyword recogniser, the LSP's hover/completion, and the TextMate grammar
// generator) is built by #including this file, so they cannot drift apart. See OFI-033.
```

It is an **X-macro table** — a C idiom where the file is a list of macro invocations and each
consumer defines the macro to mean what it needs, then `#include`s the list. Three rows, as they
appear in the file:

```c
EMBER_KEYWORD(TOK_LET,        "let",        "declaration", "`let` — bind a value to an immutable name.")
EMBER_KEYWORD(TOK_VAR,        "var",        "declaration", "`var` — declare a reassignable (mutable) variable.")
EMBER_KEYWORD(TOK_FN,         "fn",         "declaration", "`fn` — declare a function.")
```

Note the fourth column: every keyword carries its own one-line documentation, *in the vocabulary
file*, and that gloss is what your editor shows when you hover the keyword. The lexer consumes the
same table by defining `EMBER_KEYWORD` to build a lookup array — this is
[`src/lexer.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/lexer.c), in full:

```c
// keyword_type returns the reserved-word token for a lexeme, or TOK_IDENT if the
// lexeme is an ordinary identifier. Linear scan over a small table is plenty
// fast at this scale and keeps the keyword set in one obvious place.
static TokenType keyword_type(const char *text, size_t length) {
    static const struct {
        const char *word;
        TokenType   type;
    } KEYWORDS[] = {
        // The reserved-word set is generated from the single source of truth so the lexer
        // cannot drift from the LSP or the editor grammar (see include/vocab.def, OFI-033).
        #define EMBER_KEYWORD(tok, word, cat, gloss) { word, tok },
        #include "vocab.def"
    };
    size_t count = sizeof(KEYWORDS) / sizeof(KEYWORDS[0]);
    for (size_t i = 0; i < count; i++) {
        if (strlen(KEYWORDS[i].word) == length &&
            memcmp(KEYWORDS[i].word, text, length) == 0) {
            return KEYWORDS[i].type;
        }
    }
    return TOK_IDENT;
}
```

Yes, that is a linear scan, and the comment owns it: Ember has 31 reserved words (plus 25 built-in
functions and 14 primitive type names in the same file), and scanning a 31-entry table is not
where a compiler's time goes. When the count is this small, *obvious* beats *clever*. The editor
grammar is generated from the same table by a build-time tool, and `make test` regenerates it and
fails if the checked-in copy is stale — the single-source-of-truth discipline is enforced, not
aspirational.

### Newlines are grammar here

Ember has no semicolons, so the lexer carries one more responsibility: deciding which line breaks
*mean* something. The rule (decided in the manifesto while the parser was being built) is that a
newline becomes a `TOK_NEWLINE` — an implicit statement terminator — only when the last token on
the line *can end a statement*: an identifier, a literal, a closing bracket, `?`, or
`return`/`break`/`continue`. After anything that promises continuation — an operator, a comma, an
opening paren, `->` — the newline is suppressed, so a long expression may break across lines
without ceremony. You write ordinary line-broken code; the lexer does the punctuation.

### What the suite sees

The lexer's regression test,
[`tests/lexer/literals.em`](https://github.com/kmcnally5/ember-lang/blob/main/tests/lexer/literals.em),
starts with two unremarkable lines:

```ember
let i        = 0
let big      = 1000000
```

and the golden file `tests/lexer/literals.tokens` locks what `--emit=tokens` prints for them —
position, category, spelling:

```
   7:1    LET         let
   7:5    IDENT       i
   7:14   ASSIGN      =
   7:16   INT         0
   8:1    NEWLINE     
   8:1    LET         let
   8:5    IDENT       big
   8:14   ASSIGN      =
   8:16   INT         1000000
   9:1    NEWLINE     
```

There is the newline rule in action — a `NEWLINE` token after each complete statement, stamped
with the position where the next line begins.

One last behaviour worth knowing: on garbage input the lexer does not give up. An unrecognised
lexeme becomes a `TOK_ERROR` token, the error is recorded, and scanning continues — so one run
reports every lexical problem in the file rather than the first. That is not politeness; it is the
error-tolerant frontend the language server requires (Chapter 15), designed in from the start.

> **In plain terms.** The lexer reads your program the way you'd read a sentence — splitting it
> into words and punctuation, noting where each one sits, without yet asking what any of it means.
> Ember keeps its entire vocabulary (every keyword, built-in, and type name, each with its own
> one-line dictionary definition) in one file that the compiler, the editor plugin, and the
> documentation all read, so no copy can quietly go stale. And because Ember has no semicolons,
> the lexer is also the thing that decides which line breaks end a statement.

> **Machine-room trivia.** The trickiest customer in the lexer isn't a keyword — it's the dot.
> When the scanner sees `3.` it must look ahead to decide *float or field access*: `3.14` is one
> FLOAT token, but `obj.field` must stay IDENT-DOT-IDENT. The test file that locks this behaviour
> calls it out by name in its header comment, because it is exactly the kind of decision that
> breaks silently when someone "simplifies" a scanner.

---

## Chapter 5 — Shape: The Parser

Tokens are words; the parser finds the sentences. Its output is the **abstract syntax tree** — the
AST, the data structure every later stage works on — and its method is the oldest respectable one
in the book: **recursive descent**. One C function per grammatical construct; `parse_if` calls
`parse_expression` which may call `parse_unary` which may find a parenthesis and call all the way
back down. The grammar lives in the *shape of the call graph*, and the tree under construction
mirrors the call stack discovering it. No parser generator, no grammar tables: 1,999 lines of
plain C in [`src/parser.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/parser.c) you
can single-step through.

The parser's entire mutable state fits in one struct:

```c
// Parser holds the scan position over a token array plus the arena that owns the
// resulting tree. `no_struct` suppresses brace struct-literals while parsing the
// condition/scrutinee of if/for/match, so the following `{` reads as a block
// rather than a struct literal (the same disambiguation Rust uses). `panic`
// suppresses cascading messages until the next synchronisation point.
typedef struct {
    const Token *toks;
    size_t       count;
    size_t       pos;
    Arena       *arena;
    const char  *src_name;
    int          had_error;
    int          panic;
    int          no_struct;
    int          depth;          // recursion depth of the expr/type descent (overflow guard)
} Parser;
```

Those last four `int`s are four war stories in miniature. Take them in turn.

**`had_error` and `panic` — keep going, quietly.** When the parser hits a syntax error it reports
it, raises the `panic` flag, and *synchronises*: it skips tokens until a statement boundary, drops
the flag, and resumes parsing. While panicking it stays quiet, because one real mistake tends to
make the next five tokens nonsense too, and a compiler that prints six errors for one typo is
teaching you to ignore it. The result: one run reports each genuine problem once — and the parser
never stops producing a tree, which the language server (running this same parser on your
half-typed code, on every keystroke) depends on absolutely.

**`no_struct` — one bit of context.** `if x { ... }` is ambiguous in a brace language with struct
literals: is `x { ... }` a struct being built, or is `x` the condition and `{` the block? Ember
resolves it the way Rust does — inside an `if`/`for`/`match` head the brace means *block* — and
the entire mechanism is this one flag, set while parsing those positions.

**`depth` — a guard against your parenthesis key.** Recursive descent means *actual* C recursion,
and a file containing ten thousand `(`s would otherwise ride the call stack into a segfault. Every
expression operand passes through one choke point that counts:

```c
// Cap on recursive-descent nesting for expressions and types. Hand-written recursive
// descent has no stack-overflow protection, so deeply nested input (`((((…))))`, a long
// `---…` chain, `[[[…]]]`) would otherwise crash emberc with a SIGSEGV instead of a clean
// diagnostic. 1000 is far beyond any human-written nesting yet leaves ample C stack.
#define MAX_PARSE_DEPTH 1000
```

A thousand levels deep, you get a polite "expression nests too deeply" instead of a crash. Nobody
writes code like that; fuzzers and adversaries do, and a compiler should outlast both.

### Precedence, climbed rather than tabled

Expressions get the one genuinely elegant trick in the file. How do you make `1 + 2 * 3` come out
as `1 + (2 * 3)` without writing a grammar rule per precedence level? **Precedence climbing** — a
compact form of Pratt parsing. Every binary operator has a number (`binary_prec`); the function
takes the minimum precedence it is willing to bind:

```c
static Expr *parse_binary(Parser *p, int min_prec) {
    Expr *left = parse_unary(p);
    if (left == NULL) {
        return NULL;
    }
    for (;;) {
        int prec = binary_prec(pk(p));
        if (prec == 0 || prec < min_prec) {
            break;
        }
        TokenType op = pk(p);
        adv(p);
        Expr *right = parse_binary(p, prec + 1);
        Expr *e = new_expr(p, EXPR_BINARY);
        e->line = left->line;   // the expression starts at its left operand
        e->col  = left->col;
        e->as.binary.op    = op;
        e->as.binary.left  = left;
        e->as.binary.right = right;
        left = e;
    }
    return left;
}
```

Read it with `1 + 2 * 3` in hand. The call parses `1`, sees `+`, and recurses for the right-hand
side — but at `prec + 1`, meaning *"only take operators that bind tighter than my `+`"*. That
inner call parses `2`, sees `*`, which does bind tighter, so `2 * 3` is built inside the
recursion and returned as a finished sub-tree, which becomes `+`'s right child. Twenty-two lines,
every precedence level Ember has, and associativity falls out of the `+ 1`. The parser's
regression suite locks the result — from
[`tests/parser/expressions.em`](https://github.com/kmcnally5/ember-lang/blob/main/tests/parser/expressions.em):

```ember
let a = 1 + 2 * 3 - 4 / 2 % 2
```

and the corresponding lines of the golden tree in `tests/parser/expressions.ast`, exactly as
`--emit=ast` prints them:

```
      Let a
        Binary MINUS
          Binary PLUS
            Int 1
            Binary STAR
              Int 2
              Int 3
          Binary PERCENT
            Binary SLASH
              Int 4
              Int 2
            Int 2
```

Indentation is parenthood: the whole expression is a `MINUS` whose left arm is `1 + (2 * 3)` and
whose right arm is `(4 / 2) % 2`. If a change to the parser ever reshapes this tree, `make test`
catches the drift before any human notices.

### Two production details

**Children are gathered on scratch, kept in the arena.** While parsing a block the parser can't
know how many statements are coming, so children accumulate in a small malloc-backed vector; when
the list is complete it is copied into the arena (Chapter 6) in one shot and the scratch is freed:

```c
// vec_to_arena copies the gathered elements into the arena, reports the count,
// frees the scratch buffer, and returns the arena array (NULL when empty).
static void *vec_to_arena(Arena *arena, Vec *v, size_t *out_count) {
    *out_count = v->len;
    void *out = NULL;
    if (v->len > 0) {
        out = arena_alloc(arena, v->len * v->elem);
        memcpy(out, v->data, v->len * v->elem);
    }
    free(v->data);
    v->data = NULL;
    v->len  = 0;
    v->cap  = 0;
    return out;
}
```

The finished tree is contiguous, counted arrays all the way down — no linked lists to chase, and
nothing in the tree owns memory individually.

**The `>>` problem, solved the industry's way.** Shift operators mean `>>` must lex as one token;
nested generics mean `Box<Box<int>>` needs it to be two `>`s. This is the classic C++98 collision,
and Ember adopts the C++11/Rust/Java resolution: lex `>>` greedily, and at the three places the
*type* parser expects a closing `>`, split the token back in two — rewriting it in place and not
advancing, so the enclosing list consumes the remainder. The alternative (never merging, and
detecting `>>` by adjacency in the expression parser) was rejected for a recorded reason: it would
make `a >> b` parse differently from `a > > b`, and whitespace-sensitive operators surprise humans
and language models alike.

> **In plain terms.** The parser turns the word-stream into a family tree of meaning — this `+`
> owns that `1` and that `2 * 3` — using nothing fancier than functions calling each other in the
> shape of the grammar. It keeps reading after a mistake (so it can tell you everything wrong in
> one pass, and so your editor still gets a usable tree while you're mid-keystroke), it caps how
> deep an expression may nest (so a malicious file can't crash it), and its judgements about
> operator precedence are locked by recorded test output that fails the build if they ever shift.

---

## Chapter 6 — The Tree and the Arena

The AST is the compiler's central data structure — the thing the parser builds, the checker
annotates, and both backends consume — so it is worth pausing on what a node actually looks like
and where it lives. Both answers are in
[`include/ast.h`](https://github.com/kmcnally5/ember-lang/blob/main/include/ast.h), and both are
deliberately boring in the best C tradition.

A node is a **tagged union**: a `kind` field saying which construct this is, position fields, and
a union of per-kind payloads. There are five node families — types, expressions, statements,
patterns, and declarations — and each family's kinds are a plain enum. Expressions, in full:

```c
typedef enum {
    EXPR_INT,
    EXPR_FLOAT,
    EXPR_STRING,
    EXPR_BOOL,
    EXPR_IDENT,
    EXPR_UNARY,      // !x, -x
    EXPR_BINARY,     // a + b, a == b, a && b
    EXPR_CALL,       // callee(args)
    EXPR_GET,        // object.field
    EXPR_INDEX,      // object[index]
    EXPR_ARRAY,      // [a, b, c]
    EXPR_STRUCT_LIT, // Name { field: value }  /  Name<T> { ... }
    EXPR_TRY,        // expr?   (error propagation)
    EXPR_FN_VALUE,   // a named function used as a value (checker rewrites EXPR_IDENT)
    EXPR_LAMBDA,     // |params| expr   or   |params| { ... }
    EXPR_RANGE       // a..b   (exclusive integer range; valid only as a `for` iterator)
} ExprKind;
```

Sixteen kinds of expression. That's the language, on one screen.

The struct behind that enum carries something less usual, though, and it is one of the quiet load-
bearing designs of the whole compiler: alongside the parser-filled fields, an `Expr` has a band of
**checker-set annotation fields** — things like `moves_local` (does evaluating this expression
consume a binding?), `num_kind` (which numeric width should the arithmetic use?), `resolved_fn`
(exactly which function does this call target?), witness records for generic dispatch, and struct
ids for layout. The parser leaves them blank; the type checker, as it proves things about the
tree, **writes its conclusions onto the tree**; and the rule downstream is absolute: *codegen
reads annotations, it never re-resolves.* Both backends key off the same recorded decisions, which
is a big part of why a second backend (Chapter 11) was affordable at all — and why the two cannot
disagree about what a call means, only about how to say it.

One deliberate absence: the tree printer
([`src/ast_print.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/ast_print.c), the
`--emit=ast` output you saw in Chapter 5) prints **no source positions**. That output is locked by
golden files, and a dump that included line numbers would make every golden churn each time a
comment shifted a test file's code down a line. Stability is a feature you design for, even in
debug output.

### Wholesale memory

Now, where do ten thousand nodes live? The answer is 94 lines long —
[`src/arena.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/arena.c), the smallest file
in the compiler and the foundation under everything. An arena is memory rented **wholesale**: big
blocks are allocated, a cursor walks forward through the current block handing out slices, and
nothing is ever freed individually — when the compilation is done, the whole arena is released in
one sweep. The allocator, complete:

```c
void *arena_alloc(Arena *arena, size_t size) {
    size = align_up(size, ARENA_ALIGN);

    if (arena->head == NULL || arena->head->used + size > arena->head->capacity) {
        // A request larger than the standard block gets its own exact block so
        // we never refuse it; otherwise use the configured block size.
        size_t capacity = size > arena->block_size ? size : arena->block_size;
        ArenaBlock *block = new_block(capacity);
        block->next = arena->head;
        arena->head = block;
    }

    void *ptr = arena->head->data + arena->head->used;
    arena->head->used += size;
    return ptr;
}
```

Blocks default to 64 KiB; an oversized request gets its own exact-sized block so the arena never
says no; every pointer is aligned for any C type. Allocation is, in the common case, an addition
and a comparison — and *deallocation of the entire syntax tree* is a loop that frees a handful of
blocks. This fits the compiler's shape perfectly: a batch process with phases, whose data has one
collective lifetime. There is no per-node bookkeeping because there is nothing to book-keep. The
same file provides `arena_strndup`, which is how the parser copies an identifier's bytes out of
the source buffer at the moment it decides to keep them — the one copy those zero-copy tokens of
Chapter 4 were deferring.

The design has exactly one sharp edge, and the project cut itself on it early: **arena memory is
not zeroed.** A freshly allocated node contains whatever the last compilation phase left in that
block, so every field of every node kind must be initialised at its creation site. Forget one, and
you get a bug that appears only when block reuse happens to leave the wrong garbage in the right
place — maddeningly intermittent. That failure class got a number (OFI-026), a fix pass, and a
standing convention; the [architecture decision](architecture.md) records the gotcha so nobody
rediscovers it the hard way.

> **In plain terms.** The program's family tree is made of small labelled boxes ("this is a call",
> "this is a number"), and as the compiler proves facts about the program it pencils its findings
> directly onto the boxes, so later stages just read the pencil marks instead of re-deriving
> anything. All the boxes live in a few big slabs of memory that are thrown away together when the
> compile ends — like doing a jigsaw on a tray so that cleanup is "lift tray, tip" — with the one
> house rule that a new box arrives full of old junk and you must fill in every blank yourself.

> **Machine-room trivia.** `ArenaBlock` ends with `unsigned char data[];` — a C *flexible array
> member*, meaning header and storage are one allocation and the usable bytes simply begin where
> the header stops. It is also why the out-of-memory message can honestly say which subsystem
> died: there are so few `malloc` call sites in the compiler that each one gets its own epitaph.

---

## Chapter 7 — Meaning: The Checker

[`src/check.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/check.c) is 8,981 lines —
between a quarter and a third of the entire compiler, and more than twice the size of anything
else in it. That ratio *is* Ember's design philosophy, stated in code volume: the language's
promises — ownership without lifetime annotations, generics checked at the definition, contracts,
linear FFI handles, refinement types — are compile-time promises, and this is where every one of
them is kept. The lexer spells, the parser shapes, the backends translate; the checker is where
the language actually lives.

Its first job is ordinary: resolve every name, infer every local's type, verify every signature.
The representation it does this with is worth showing, because it is so plainly a C programmer's
answer to a type-theory problem. A type, to the checker, is an `int`:

```c
// A semantic type. Encoded as an int so existing == comparisons keep working
// and struct types slot in with no churn: negative values are the primitives,
// and any value >= 0 is a struct-type id (index into the checker's struct table).
typedef int SemType;
#define TY_ERROR (-1)
#define TY_INT   (-2)   // the default integer; an alias for i64
#define TY_BOOL  (-3)
#define TY_SELF  (-4)   // placeholder in an interface signature for the impl type
#define TY_FLOAT (-5)
#define TY_STRING (-6)
#define TY_UNIT  (-7)   // result of a statement-only call (e.g. print); not a value
```

Primitives are small negative numbers; everything composite is a non-negative id, and the
non-negative range is carved into **bands of a million**:

```c
#define ENUM_BASE    1000000
#define PARAM_BASE   2000000
#define GENERIC_BASE 3000000
#define ARRAY_BASE   4000000   //   [ARRAY_BASE, CHANNEL_BASE) array type; elem table
#define CHANNEL_BASE 5000000   //   [CHANNEL_BASE, FN_BASE)    channel type; elem table
#define FN_BASE      6000000   //   [FN_BASE, IFACE_BASE)      function type; fntype table
#define IFACE_BASE   7000000   //   [IFACE_BASE, SLICE_BASE)    interface value type; id = t - IFACE_BASE
#define SLICE_BASE   8000000   //   [SLICE_BASE, ...)          Slice<T> view; shares the array elem table
#define NEWTYPE_BASE 9000000   //   [NEWTYPE_BASE, ...)        newtype (OFI-149); id = t - NEWTYPE_BASE; base in c->newtypes[id]
```

A `SemType` of `4000017` means "array type number 17 — go look up its element type in the array
table." The accompanying comment makes the safety argument out loud: *no program approaches a
million of anything*. Types compare with `==`, store in plain `int` fields, and cost nothing to
copy — and when the language grew slices and newtypes, each simply took the next band. It is not
how the textbooks do it. It has needed exactly one adversarial fix (a band-overlap found during
the newtype work, caught in review), and it has carried nine language features without a
rewrite.

### The part that makes Ember Ember

Then comes ownership. The checker enforces the manifesto's memory model — every value has one
owner; a plain use is an immutable borrow; `mut` borrows visibly; `move` transfers, and the
checker tracks per-binding state so a moved-from binding cannot be touched again. There are no
lifetime annotations to check because the analyses are chosen to not need them: borrows are
function-local, ownership transfer is explicit, and the graph-shaped escape hatches (`slotmap`,
`rc struct`) are types, not annotations. The `Copy` story is one clean rule: everything copies
freely *except* the unique-owner aggregates (structs and arrays) — scalars copy bitwise, and
strings, enums, and closures are immutable and reference-counted, so "copying" one is a permitted,
cheap alias.

Two dataflow analyses deserve a sentence each, because they are duals and the symmetry is lovely.
*Use-after-move* needs "was this moved on **some** path?" — so at every control-flow join the
checker **OR-merges** each binding's moved flag. *Linear `Ptr` handles* (Chapter 16 — a foreign
handle must be closed on **every** path) need the opposite: an **AND-merge** of a consumed flag
across the same joins. Same walk, same join points, inverted lattice — and the leak check is
purely compile-time, costing the runtime nothing.

The checker is also where the tree gets its pencil marks (Chapter 6): which bindings need a drop
emitted at scope exit, which reads must bump a refcount, which calls resolve to which function
slot, which numeric width each operator uses. And it is where **generics are checked once, at the
definition**, against declared interface bounds — not re-checked per use, which is the recorded
answer to C++'s template-error experience. Generic dispatch happens through **witness records**
(dictionary passing): a small table of the concrete type's method indices, built where the
concrete type is known, threaded to where it isn't — from
[`include/ast.h`](https://github.com/kmcnally5/ember-lang/blob/main/include/ast.h):

```c
// A witness: a concrete type's method fn-indices for one bound interface, in the
// interface's method order. Passed to bounded generic code so it can dispatch an
// interface method on an erased type parameter (dictionary passing).
typedef struct {
    const int *fns;
    int        count;
} Witness;
```

The same witness record, boxed, *is* the vtable inside a dynamic interface value — one mechanism
serving both static bounds and runtime polymorphism. What runs today, on both backends, is this
erased, uniform-representation form; the manifesto's recorded plan of monomorphizing for release
builds remains exactly that — a recorded plan, not a shipped fact.

A word on the errors themselves, because the manifesto elevates them to a founding principle
("the compiler is a teacher — diagnostics are part of the language spec, not an implementation
detail"). Checker errors are phrased in terms of *your program*, they carry the nearby source
text, and where the fix is known they say it. When the checker rejects a move-after-move, the
message names the binding and where it moved. The machinery those messages flow through is the
next chapter.

> **In plain terms.** The checker is the compiler's court: every name must identify something,
> every type must line up, and — Ember's distinctive rule — every value must have a clear owner at
> every moment, so that freeing memory twice or using something after giving it away becomes a
> *rejected program* instead of a 2 a.m. crash. It writes its verdicts onto the program's tree for
> the later stages to obey, and it is the biggest piece of the compiler by far, because it is
> where most of the language's promises are kept.

> **Machine-room trivia.** `TY_SELF` is negative four: the type "whatever type ends up
> implementing this interface" is, to the checker, just another small negative integer with a
> comment. Somewhere a type theorist felt a disturbance and could not say why.

---

## Chapter 8 — When Things Go Wrong

Most compilers treat errors as prose: text sprayed at stderr, formatted for a human squinting at a
terminal. Ember treats a failure as **an artifact** — a structured record with named parts — and
then *renders* that record for whoever is reading. This is one design applied twice, at the two
places a program can fail.

**Compile-time.** Every diagnostic in the frontend funnels through one function, `diag_error` in
[`src/diag.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/diag.c) — 209 lines, one of
those files whose smallness is the point. A diagnostic carries file, line, column, message, the
nearby source text, an optional `help` (a concrete suggested fix), and an optional secondary
location ("the value moved here"). In human mode it prints immediately, in the familiar
`file:line:col: error: …` shape. Pass `--diagnostics=json` and nothing about the analysis changes
— the same records are instead collected and emitted as **JSON Lines**, one object per line,
machine-parseable, made for a tool or a model that intends to *fix* the program rather than read
about it.

**Run-time.** The richer sibling is the **Fault** — Ember's single structured failure artifact,
defined in [`include/fault.h`](https://github.com/kmcnally5/ember-lang/blob/main/include/fault.h)
and documented in [faults.md](faults.md). The taxonomy first:

```c
typedef enum {
    FCAT_PARSE,           // lexer/parser error
    FCAT_TYPE,            // type / borrow / linearity error
    FCAT_CONTRACT,        // requires/ensures/assert violation
    FCAT_RUNTIME,         // a builtin trap: index, divide-by-zero, overflow, shift, slice, …
    FCAT_UNHANDLED_ERR,   // an Err/None reached main
    FCAT_COUNTEREXAMPLE   // --check falsified an ensures
} FaultCategory;
```

Every way an Ember program can fail is meant to converge on this one record. And the record
itself is a small anatomy lesson in what a good error *contains*:

```c
typedef struct {
    FaultSeverity severity;
    FaultCategory category;
    const char   *code;       // stable machine handle, e.g. "index_out_of_bounds"; borrowed/static
    const char   *message;    // one-line human summary; borrowed/static
    const char   *file;       // source path, or NULL if unknown at this site; borrowed
    const char   *fn;         // function the failure surfaced in, or NULL; borrowed
    int           line;       // 1-based; 0 = unknown
    int           col;        // 1-based column of the failing expression; 0 = unknown (OFI-111a)
    const char   *why;        // the violated intent ("indexing requires 0 <= index < len"), or NULL
    const char   *hint;       // a concrete suggested fix in user terms, or NULL
    FaultValue    values[FAULT_MAX_VALUES];
    int           value_count;
    FaultHop      route[FAULT_MAX_HOPS];
    int           route_count;
} Fault;
```

Look at what earns a field. `why` is the **violated intent**: an index trap doesn't just say what
happened, it states the rule that was broken — "indexing requires `0 <= index < len`" — as if the
built-in had a contract, because conceptually it does. `values` are the **actual operands**,
projected from the live VM at the moment of failure — the real index, the real length — never
reconstructed, never guessed; the header's own comment insists *never hallucinated*. `route` is
the call chain the failure surfaced through. And `hint` is the fix, when one can honestly be
suggested. The design brief behind those fields: *the violated intent* and *the concrete effect*
are the two strongest signals for automated program repair, and they turn out to be exactly what
a tired human wants at 2 a.m. too.

One record, two faces. `--faults=agent` switches the renderer from the human stderr stream to one
escaped JSON object per line. The fault machinery is Phase 1 complete (the builtin runtime traps);
routing the *compile-time* categories onto the same record, and a couple of precision items, are
tracked openly in the OFI log as the remaining phases — the file's comments say so themselves,
which is this project's way.

> **In plain terms.** When an Ember program fails, the compiler builds a little incident report —
> what rule was violated, with which actual values, reached through which calls, and (when
> honest) how to fix it — and only *then* decides how to print it: as friendly text for a person,
> or as machine-readable lines for a tool or an AI that will attempt the repair itself. Same
> facts, two audiences.

> **Machine-room trivia.** `FaultValue` stringifies each operand into a fixed inline buffer —
> `char rendered[256]` — rather than allocating. Why? Because the report is assembled *on the
> abort path*, possibly while the heap is the thing that just went wrong. A failing program
> shouldn't have to allocate memory to explain itself.

---

# Part III — Running It

## Chapter 9 — Lowering: Bytecode

The checked, annotated tree now becomes something executable.
[`src/codegen.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/codegen.c) walks the AST
and emits **stack bytecode**: flat arrays of instructions for a machine with no registers, just a
stack of values. There is deliberately no optimizing intermediate representation between tree and
bytecode — the recorded reasoning is that an IR is "more surface to keep in sync," and Ember's
speed story for release builds is the native backend, not a cleverer interpreter.

Time to keep Chapter 3's promise. Our traveller, `tests/codegen/functions.em` once more:

```ember
// functions.em — locks multi-function bytecode and the OP_CALL instruction.
fn add(a: int, b: int) -> int {
    return a + b
}
fn main() -> int {
    return add(2, 3)
}
```

and what the suite locks for `--emit=bytecode`, the golden file
[`tests/codegen/functions.bytecode`](https://github.com/kmcnally5/ember-lang/blob/main/tests/codegen/functions.bytecode),
in full:

```
== fn add (arity 2) ==
0000    3  GET_LOCAL 0
0002    |  GET_LOCAL 1
0004    |  ADD      0
0006    |  RETURN  
0007    |  CONST    0  (= 0)
0009    |  RETURN  
== fn main (arity 0) ==
0000    6  CONST    0  (= 2)
0002    |  CONST    1  (= 3)
0004    |  CALL     0 2
0007    |  RETURN  
0008    |  CONST    2  (= 0)
0010    |  RETURN  
```

Read `add` line by line. The first column is the byte offset of the instruction; the second is the
source line it was lowered from (`3`, then `|` meaning "same line as above" — the chunk carries a
parallel line table precisely so errors and the tape can point back at your source).
`GET_LOCAL 0` and `GET_LOCAL 1` push the two parameters onto the stack; `ADD 0` pops both and
pushes their sum (the `0` operand is the numeric-kind byte — this is 64-bit integer addition);
`RETURN` hands the top of the stack back to the caller. In `main`: two `CONST` instructions push
`2` and `3` from the function's constant pool (the disassembler helpfully shows `(= 2)`), and
`CALL 0 2` invokes function number 0 — `add` — with two arguments. The trailing `CONST 0 / RETURN`
pair in each function is the safety net for a fall-off-the-end return; here it is unreachable, and
two bytes is a cheap price for never wondering.

### One table to rule the instruction set

The instruction set itself lives in
[`include/opcode.h`](https://github.com/kmcnally5/ember-lang/blob/main/include/opcode.h) as
another X-macro table, and its header comment explains exactly why with the candour this codebase
makes a habit of:

```c
// The single source of truth for Ember's bytecode instruction set.
//
// Each row is  X(enum-name, "mnemonic", OPERANDS)  where OPERANDS is OPS0()..OPS5(...) listing each
// inline operand's KIND in stream order (OperandKind below). One declaration drives four things that
// must agree or the VM desyncs far from the cause: the operand WIDTHS the disassembler advances by,
// the bytes codegen WRITES, the bytes the VM READS, and the round-trip codec. They share one codec
// keyed by these kinds, so they cannot drift — the class behind OFI-007/047/056 (a narrow operand
// silently wrapping). `make opcheck` proves the codec round-trips AND that every VM handler consumes
// exactly what its spec declares, across the whole test corpus.
```

Four consumers — the code that writes an instruction, the code that executes it, the disassembler,
and the shared codec — derived from one declaration, so they *cannot* disagree about an
instruction's shape. The same file's compile-time trick is worth knowing: the codegen and VM
`switch` statements over opcodes have **no `default:` arm**, so `-Wswitch` (promoted to an error
by `-Wall -Werror`) fails the build the instant someone adds an opcode without adding its
handlers. Exhaustiveness checking, imported into C for free.

### The 256 ceiling, and how it stopped being a bug class

Those OFI numbers in the comment are a saga worth telling properly, because it shows how this
project converts pain into structure. Early bytecode operands were fixed-width — often one byte.
A one-byte constant-pool index works until some function has 257 literals; then the index *wraps
mod 256* and the VM silently loads the **wrong constant**. Not a crash: a miscompile. The class
struck three separate times (OFI-007: function indices; OFI-047: struct ids; OFI-056: a large
render function's string pool), each found reactively, each patched — first by widening what one
function could overflow, then by guarding what whole programs plausibly couldn't.

The 2026-06-18 resolution retired the whole question. Every index-like operand is now the
`OPK_IDX` kind:

```c
    OPK_IDX,     // an unbounded index/count/slot/id as unsigned LEB128 (1 byte for values < 128).
                 // The modern, cap-free encoding for every pool index, local slot, field index,
                 // struct/enum/function id, and count — no value can overflow it (OFI-007/047/056).
```

**LEB128** — a variable-length integer encoding, one byte for values under 128, growing as needed,
with no ceiling to hit. The miscompile class is, in the log's words, *structurally gone, not just
guarded*. (Jump offsets stay fixed 16-bit, for the honest reason the header states: a jump
distance is back-patched after the target is known, so its width must be decided in advance.) The
compiler's own fixed-size internal tables were made dynamic in the same campaign, and a standing
stress-gate — `make ceilings`, Chapter 14 — pushes every dimension past its old limits on every
run to prove that nothing wraps and nothing crashes; each dimension must either work or fail with
a clean "too many" error. A limit is acceptable. A silent wrap never is.

> **In plain terms.** The tree is flattened into a to-do list for a little pretend calculator that
> keeps everything on a stack: push 2, push 3, call `add`, hand back the answer. The list's
> encoding was once bitten by fields too small for big programs — like a car odometer rolling
> over — so the project switched every count and index to a stretchy number format that simply
> grows, and then built a permanent test that tries to overflow everything, on every test run, to
> keep it that way.

> **Machine-room trivia.** The widest instruction in the set is `FOR_ARRAY`, whose five operands
> (array, index, length, and loop-variable slots, plus the exit jump) set the
> `EMBER_MAX_OPERANDS 5` constant for everyone else. Iterating an array is apparently the most
> demanding sentence in the machine's language.

---

## Chapter 10 — The Machine: The VM

[`src/vm.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/vm.c) is the second-largest
file in the compiler (5,003 lines) and the place where Ember's promises stop being analysis and
start being behaviour. It is a classic stack interpreter: a value stack, a stack of call frames
(function + instruction pointer + where its locals begin), and a dispatch loop that reads an
opcode and does the thing. The VM is also, by written decision, the **reference semantics** of the
language — whatever subtle question you have about what Ember means, the VM's answer is the
canonical one, and everything else (the native backend, the self-hosted port) is measured against
it.

A running value is sixteen bytes — from
[`include/value.h`](https://github.com/kmcnally5/ember-lang/blob/main/include/value.h):

```c
typedef struct {
    ValueType type;
    union {
        int64_t integer;
        double  floating;
        Obj    *obj;
    } as;
} Value;
```

A tag and a payload: an inline 64-bit integer (bools ride along as 0/1), an inline double, or a
pointer to a heap object. No NaN-boxing, no pointer tagging — the header comment calls the choice
by name: keeping values a fixed, simple size keeps the stack uniform, and the ownership story
lives in the compile-time discipline *above* this representation, not in runtime cleverness.

Heap objects — structs, strings, arrays, channels, closures, interface values — share a common
`Obj` header carrying the object's type, its links in a doubly-linked list of all live objects
(so a scope-exit drop unlinks in O(1), and an end-of-run sweep can free stragglers), a `home`
pointer for cross-thread hygiene under the parallel runtime, and a refcount. The refcount is where
Chapter 7's compile-time ownership model shows its runtime face, and the split is exact:
**unique-owner aggregates** (structs, arrays) ignore their refcount and are freed directly by the
`OP_DROP` the checker planted at their owner's scope exit; **shared immutables** (strings, enums,
closures, channels) are reference-counted, because aliasing an immutable value is harmless and
counting is cheap. Dead objects aren't even returned to `malloc` straight away — a `size_class`
field lets the next same-sized allocation recycle the block, which matters in loops that churn
`Some(x)` wrappers.

String literals get one more courtesy. The chunk's string pool interns each literal on first
execution — the pool entry caches the heap object and keeps its own reference — so a literal
inside a hot loop is one allocation for the whole run:

```c
// push_string_const interns a string-literal pool entry on first use (the chunk keeps its own
// reference so the object outlives every program copy) and pushes a counted reference; later
// executions just bump the refcount.
static int push_string_const(VM *vm, StringConst *sc) {
    ObjString *s = sc->cached;
    if (s == NULL) {
        s = make_string(RT(vm), sc->length);
        memcpy(s->chars, sc->data, sc->length);
        OBJ_RETAIN(&s->obj);   // the chunk's reference, held all run
        sc->cached = s;
    } else {
        OBJ_RETAIN(&s->obj);   // the pushed copy's reference
    }
    return push(vm, OBJ_VAL(s));
}
```

### The dispatch loop, and a decision with its receipts

How should an interpreter *dispatch* — pick the code for each opcode? The folk wisdom says
computed-goto "threaded" dispatch beats a `switch`, because each handler gets its own indirect
jump for the branch predictor to learn. Ember's dispatch loop supports both, and the comment above
it is this codebase in one paragraph — a decision recorded *with its evidence*:

```c
// Dispatch is a portable `switch` by default; setting EMBER_THREADED to 1 (on
// GCC/Clang) switches it to computed-goto "threaded" dispatch, where each handler
// ends with its own indirect jump to the next instruction so the CPU sees a
// distinct, separately-predicted branch per opcode rather than one shared switch
// branch. The handler bodies are identical for both — VM_CASE labels each, VM_NEXT
// dispatches the next instruction (running the trace hook first).
//
// MEASURED 2026-06-12 (Apple Silicon / arm64, clang -O2): threading is ~11% SLOWER
// here (flex_bench 0.30s -> 0.33s; `arrays` and `enums` regress most) — the M-series
// branch predictor handles the switch's single indirect branch better than the
// table-load + indirect-jump per handler. So it is OFF. It is left as a one-line
// toggle because the trade flips by microarchitecture: on x86 server cores with
// weaker indirect prediction it has historically helped, and that is worth a
// re-measure there before enabling. Do not enable without benchmarking the target.
```

The folk wisdom was measured and, on this decade's Apple silicon, found backwards. The toggle
stays in the source, one line, with instructions to re-measure before trusting it elsewhere. If
this book leaves you with one habit, let it be that comment's.

### Fibers

Concurrency lives here too. A `Fiber` owns one task's entire execution state — its value stack,
its frames, and what it's blocked on — and the same bytecode runs under three schedulers,
selected at build time. The default is **cooperative serial**: one thread, fibers taking turns,
a blocking channel operation returning `VM_YIELD` to unwind into the scheduler. `make parallel`
is **1:1**: one OS thread per spawn, atomic refcounts, per-worker allocation arenas. And
`make mn` is the **M:N green-thread scheduler**: a worker pool of roughly one OS thread per core
running thousands of cheap fibers, which *park* on channels instead of blocking their thread. The
design's key realization, recorded in [architecture.md](architecture.md), is that the VM's
interpreter loop already *was* the suspension point — a fiber's state is all in the `Fiber`
struct, so no stack-switching assembly is needed; the feared multi-week effort collapsed into
scheduling work. Structured cancellation, a global deadlock detector (all workers idle + no ready
fiber + a live fiber somewhere = report and abort, rather than hang), verified clean under
ThreadSanitizer and an 8,000-fiber stress — and still gated behind its own build flag until it
has soaked longer, because the default runtime's correctness record is not something this project
spends casually.

> **In plain terms.** The virtual machine is a tireless clerk with a stack of trays: instructions
> arrive one at a time — push this, add those, call that — and the clerk just does them. Memory
> management is split by kind: things with one owner are thrown away the moment their owner is
> done (the compiler marked exactly where), while immutable shared things carry a little counter
> of interested parties. Even the engine-room folklore about the fastest way to run the loop was
> settled by stopwatch, not by lore — and the stopwatch's verdict is written above the loop.

---

## Chapter 11 — The Second Road: Native Code

For most of its life an Ember program runs on the VM. When it graduates — `emberc -o app app.em` —
it takes the second road: [`src/cgen_c.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/cgen_c.c)
walks the *same checked, annotated AST* and emits a self-contained **C translation unit**, which
the system C compiler builds and links against a small runtime
([`src/runtime.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/runtime.c)) into a
standalone binary. No interpreter inside, no VM — and no LLVM either: the only build dependency is
the C compiler the machine already has, which keeps the empty-dependency-tree promise intact.

Why C and not bytecode-to-C, or straight to assembly? The decision is recorded: bytecode is
stack-shaped and type-erased, so lowering *it* would mean reconstructing the expression trees the
typed AST already holds — the same work, backwards, on a lossier form. Lowering from the AST
emits natural C (`a + b` becomes `a + b`), and C as a target keeps the road open to the place
this backend ultimately points: bare metal (Chapter 17).

The manifesto had said "one backend," and the amendment that welcomed this second lowering is a
nice piece of intellectual honesty — the rule that mattered was never "one backend," it was **one
frontend and one reference semantics**. The lexer, parser, and checker are shared; the VM remains
canonical; and the native backend is held to it by a **differential test suite**
([`tests/native/`](https://github.com/kmcnally5/ember-lang/blob/main/tests/native)): every program
runs on both, and their outputs must match bit for bit. Two independent implementations that must
agree — the project likes to point out this is its verification thesis, applied to itself.

The backend's craft is in representation choices, each mirroring the VM so the checker's
annotations stay truthful on both roads:

- An **all-scalar struct** becomes a real C struct, by value — construction is a compound
  literal, field access is `.f0`, and C's own value semantics provide moves, copies, and nesting.
  (The first cut boxed everything on the heap; it double-freed on moves, precisely because the
  checker's ownership flags describe the *value-type* representation. The backend must match the
  checker's world-model, and now does.)
- A struct with any heap field is a **boxed, refcounted object, exactly as the VM represents
  it** — same layout, same drop discipline, driven by the same checker flags.
- **Generics stay erased**: one C function over the uniform `Value`, matching the VM rather than
  monomorphizing, because matching the reference is worth more than a speedup that could drift.
  A value-struct crossing into a boxed aggregate is boxed on the way in and unboxed leaf-by-leaf
  on the way out — never memcpy'd, because the two layouts store scalars at different widths.
- **Closures** dispatch through a generated `em_invoke` trampoline — a `switch` over every
  all-`Value` function — because C has no uniform indirect call across arities.

Two properties of this backend deserve the emphasis the docs give them. First, **the frontier is
honest**: a construct the backend cannot yet lower is rejected with a clear error at emit time —
never mis-compiled, never approximated. Second, **the bar is leak-free, not just output-correct**:
the differential harness checks stdout, so memory discipline is verified separately by flat-RSS
stress runs over million-iteration loops. That stricter bar has already paid twice — chasing it
exposed one latent VM use-after-free and one VM temporary leak (OFI-052), both fixed. The second
implementation didn't just copy the first; it audited it.

And one flag on this road matters beyond speed: `--freestanding` emits C with no stdio, no argv,
no hosted anything — the mode the kernel experiment rides (Chapter 17).

> **In plain terms.** The same fully-checked program tree can be translated into C and compiled
> into an ordinary executable, with no Ember machinery left inside. The interpreter remains the
> official definition of what programs mean, and a permanent test runs everything both ways and
> demands identical output — so the fast version can never quietly disagree with the true one.

> **Machine-room trivia.** The native road has one open soundness item the project wears on its
> sleeve (OFI-166): C compilers may evaluate `f(a, b)`'s arguments in either order — gcc goes
> right-to-left, clang left-to-right — so an operand with a side effect could diverge from the
> VM's strict left-to-right. It was caught, naturally, by a differential test: the self-hosted
> compiler's own output shifted by two variable names on Linux gcc, and CI refused. The
> workaround is sequencing; the real fix is on the ledger.

---

# Part IV — The Truth Machinery

## Chapter 12 — The Tape

Most languages let you attach a debugger. Ember's ambition — stated in the manifesto back when
the VM was young — is different: **execution itself should be observable as data**, designed in
as a seam rather than bolted on later. (The bolt-on version was tried in Ember's ancestor and
found wanting: added late, it could only see the few checkpoints that already existed.) The seam
is [`include/trace.h`](https://github.com/kmcnally5/ember-lang/blob/main/include/trace.h), and it
is small enough to show almost whole:

```c
typedef struct {
    const char  *fn;          // name of the function currently executing
    size_t       ip;          // byte offset of the instruction in that function's chunk
    OpCode       op;          // the instruction about to execute
    int          line;        // source line it was lowered from (0 if unknown)
    const Value *stack;       // base of the value stack
    size_t       stack_count; // number of values currently on the stack
    // Semantic events (MANIFESTO §5c). NULL for an ordinary per-instruction step;
    // when set, this is a richer event whose machine-readable name is `event` (e.g.
    // "contract_violation") and whose description is `detail`. This is the closed
    // loop for an LLM author: a contract it wrote, failing, reported as structured
    // data it can act on — not just an abort.
    const char  *event;       // semantic-event name, or NULL for a plain step
    const char  *detail;      // the event's description (e.g. the contract message)
} TraceEvent;
```

The VM fires one of these immediately before every instruction, to at most one subscribed sink;
with no sink the cost is a single nil check per instruction. Sinks are **observer-only** — they
may log, write, or ask a model for an opinion, but they cannot alter execution. Run
`emberc --tape program.em` and the built-in sink writes the **tape**: one JSON object per
event, one per line — function, instruction, source line, stack depth — the complete story of a
run, in a format chosen because a tool or a model can consume it line by line. Because the events
are fired from the dispatch loop itself, the tape grows automatically with every opcode ever
added; nobody maintains a list of "traceable things."

The `event` field is where the tape earns its keep. A contract violation (Chapter 13) doesn't
just abort — it lands on the tape as `{"event":"contract_violation", …}` naming the clause and
the values. Task lifecycle, error propagation, the moments a program's story turns: the design
calls these *semantic events*, and they ride the same seam. Graphics programs get a sibling at a
saner altitude — a **frame tape** logging each frame's inputs, draw commands, and interactions
(`click`, `toggle`, `focus`), because sixty frames a second of per-instruction events is the
wrong resolution for "why did the button not press."

Two more instruments complete the kit. A special build (`-DEMBER_DROP_TRACE`) records every
ownership drop — the **memory tape** — with a double-drop detector that stamps a sentinel into a
reclaimed object's refcount so a second drop identifies *both* drop sites and aborts; the
architecture log credits this with pinning, in minutes, a class of pool-recycling bug that plain
ASan cannot see (the pool reuses memory instead of freeing it, so a use-after-free reads valid
bytes). And `--emit=replay` runs a program against a recorded fixture of its nondeterministic
inputs, the first brick of deterministic record-replay: the tape as *seed*, so a failing run —
especially an agent's failing run — can be replayed exactly.

The repo's working agreement makes the cultural point better than any summary: *"When you hit a
bug — reach for the tape tool and a dogfood app to prove/find it first! Always!"* Debugging here
means reading the program's own account of itself.

> **In plain terms.** Ember can fly with a flight recorder switched on: every step the program
> takes is written down as it happens, in a form both humans and AI tools can read back. When
> something goes wrong, you don't reconstruct the crash from memory and guesswork — you scrub the
> tape. Important moments (a broken promise, a task starting or dying) are marked out loud, and a
> special build even records every moment memory was let go, which has caught bugs ordinary tools
> can't see.

> **Machine-room trivia.** The tape once debugged the scheduler that runs it. When parallel
> nurseries still launched every task at the closing brace (pure fork–join), a GUI's poll loop
> spun forever waiting for a worker that hadn't started — a self-inflicted deadlock the project
> found *by reading the tape*, and fixed by making `spawn` launch immediately. The tape's first
> major catch was the runtime's own design.

---

## Chapter 13 — Contracts and the Little Prover

Ember functions can carry their specification in the signature: a `requires` line stating what
must be true on entry, `ensures` lines stating what the function promises on exit, with `result`
naming the return value. These are ordinary boolean expressions — the spec language is just
Ember — checked at runtime in debug builds and elided entirely by `--release` (type-checked in
every profile; only the runtime check is free to leave). The manifesto is unusually direct about
why this feature is the flagship: a language whose primary audience includes AI authors needs the
spec to be executable and the failure to be structured, because *"a model is far better at
checking 'does this implementation satisfy this constraint?' than 'does this code match this
vague comment?'"*

What makes contracts more than assertions is the tooling stacked on them, and the test suite
demonstrates the first layer with a deliberately buggy function. From
[`tests/check/contract_fuzz.em`](https://github.com/kmcnally5/ember-lang/blob/main/tests/check/contract_fuzz.em):

```ember
fn abs_val(x: int) -> int
    ensures result >= 0
{
    return x          // BUG: should negate when x < 0 — the fuzzer finds a negative counterexample
}


fn safe_div(a: int, b: int) -> int
    requires b != 0
    ensures true      // the point here is that the fuzzer respects `requires` (never divides by 0)
{
    return a / b
}
```

`emberc --emit=check` is **property-based testing driven by the contracts**: it generates inputs
that satisfy each function's `requires`, runs the function, and hunts for an input that falsifies
an `ensures`. The golden file locks what that finds — both the human report and the machine
event, from `tests/check/contract_fuzz.check`, in full:

```
check abs_val: FAILED
  counterexample: abs_val(-1)  =>  postcondition failed in 'abs_val' (ensures, line 8)
{"event":"check_failed","fn":"abs_val","input":"abs_val(-1)","detail":"postcondition failed in 'abs_val' (ensures, line 8)"}
check safe_div: ok (300 cases)
check square: ok (300 cases)
checked 3 function(s): 2 passed, 1 failed
```

The contract *is* the spec; the fuzzer interrogates it; the counterexample comes back concrete
(`abs_val(-1)`), reproducible (the generator is fixed-seed), and machine-readable. Note
`safe_div: ok` — the fuzzer respected `requires b != 0` and never fed it a zero. Out-of-domain
inputs are not bugs; that is what a precondition means.

### The prover

Above the fuzzer sits something rarer for a language this young: a static prover.
[`src/prove.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/prove.c) — 465 lines,
dependency-free like everything else — attempts to *discharge* contracts outright, and its
self-description sets the tone:

```c
// Brick 4 of the verification loop (§5j): a small, SOUND, dependency-free prover for contracts in
// the linear-integer-arithmetic fragment. It never claims a false contract is proved — anything it
// cannot model or discharge is reported as "use --check", deferring to the property fuzzer (brick
// 2). All arithmetic is exact int64 with overflow guards; on any overflow or blow-up the proof
// attempt bails to "not proved" so the result stays sound.
```

The method is **Fourier–Motzkin elimination**, an algorithm older than the electronic computer —
Fourier was eliminating variables from systems of inequalities in the 1820s. Working in the
fragment where everything is a linear form —

```c
// A linear form  Σ coeff[i]·varᵢ + konst  over the tracked integer parameters.
typedef struct {
    long long coeff[PROVE_MAX_VARS];
    long long konst;
} Linear;
```

— the prover substitutes the body's returned expression for `result`, assumes `requires` and the
*negation* of an `ensures` clause, and tries to show the combined system of inequalities has no
integer solution. Fourier–Motzkin does this by eliminating variables one at a time — projecting
the shape onto fewer dimensions, the way a shadow is a projection of a solid — until what remains
is arithmetic on constants, which is just false or true. If the system is infeasible, no input
satisfying `requires` can violate that `ensures`: **proved, for all inputs**, not three hundred
of them.

The engineering virtue here is knowing its own edges. Eight tracked variables, a
128-constraint budget, exact integer arithmetic with overflow guards — and on anything outside
the fragment (nonlinearity, a call it can't model) or any blow-up, it bails to "use `--check`."
The failure mode is *less assurance*, never *false assurance*. Your editor shows the outcome
inline (Chapter 15): each `ensures` gets a quiet `✓ proved` or `○ runtime-checked` — an honest
little annotation doing a lot of philosophical work.

The same contract machinery was then reused for **data**: refinement types
(`type Percent = int where 0 <= self && self <= 100`) check their predicate once, at
construction, so a value's type is the proof it was valid — with the check debug-only and
release-elided exactly like any contract. Contracts on functions, refinements on values, a
fuzzer to falsify, a prover to discharge, a tape to report, replay to reproduce: the docs call
this loop the language's bet for the agent era. This book will only note that all five pieces
exist, are in-tree, and are tested — and let the bet be a bet.

> **In plain terms.** An Ember function can state its promise — "given a non-zero divisor, I
> return a non-negative result" — in code that actually runs. The toolchain then attacks the
> promise from three sides: checks it live while you develop (free in production), fires hundreds
> of generated inputs at it hunting for a counterexample, and for simple-enough arithmetic
> *proves it outright*, the way you'd prove something in algebra rather than by trying examples.
> When a promise breaks, the failure arrives as structured data naming the exact promise and the
> exact values — which is precisely what you'd want whether you're a person or a machine doing
> the fixing.

> **Machine-room trivia.** `PROVE_MAX_VARS` is 8. If your function has nine integer parameters,
> the prover doesn't try to be a hero — it hands you to the fuzzer. There is something quietly
> admirable about a formal-methods tool whose first design decision is a modest opinion of
> itself.

---

## Chapter 14 — The Gates

Every project says it values testing. This one built *gates* — standing, generative,
adversarial test programs, each born from a bug class that hurt once, each promoted to a
permanent part of `make test`'s extended family so that the class can never return quietly. The
pattern repeats often enough here to be the codebase's signature move: **pain → number (an OFI)
→ fix → gate**, in that order, every time.

The roll call, and the wound each one dresses:

- **`make test`** — the base gate: the golden-file regression suite (tokens, ASTs, bytecode,
  runs, faults, contracts — 428 goldens passing at the time of writing) plus `make doctor`'s
  setup health-check. Everything in this book that quoted a golden is enforced here.
- **`make opcheck`** — *operand drift* (the OFI-007/047/056 class, Chapter 9). Proves the
  encode/decode codec round-trips every operand kind, then runs a special VM build that asserts,
  after **every instruction across the whole corpus**, that the handler consumed exactly the
  bytes the spec declares. Proven with teeth: inject drift on purpose and the gate fails.
- **`make ceilings`** — *silent truncation*. For each compiler dimension (constants, strings,
  locals, functions, fields, variants…) it generates a program that pushes **past** the old 256
  boundary and folds the values into a printed checksum. Two outcomes are legal: WORKS (right
  checksum, VM and native agreeing) or CAPPED (a clean "too many" error). A crash, a wrong
  checksum, or a VM≠native split fails. On its first run it found two silent-truncation bugs;
  they are its baseline now.
- **`make crucible`** — *memory ownership*, the big one. A seeded generator builds whole
  programs in the danger zone (value structs — flat, heap-bearing, nested — pushed through
  erased-generic containers, moved, borrowed, returned, mutated in loops) and runs each through
  **five oracles**: the double-drop detector, AddressSanitizer, an RSS leak check, the VM↔native
  differential, and a runtime-fault check. Findings dedupe and **shrink to a minimal repro**; a
  baseline file means only a *new* signature fails the build. The recurring memory bugs all
  lived at cross-feature combinations nobody would think to hand-write; Crucible found a live
  one (OFI-063) within minutes of first running.
- **`make ledger`** — *linear-handle analysis correctness* (Chapter 16's must-close-on-every-path
  `Ptr` rule). Generates handle-lifetime programs with a **known** accept/reject verdict and
  checks the compiler agrees both ways — catching a leak that compiles *and* a sound program
  wrongly rejected. Its first catch was real: a false "leak" reported on statically-dead code.
- **`make mn-stress`** — *the M:N scheduler*, fuzzed with concurrent programs whose answers are
  deterministic by construction, under a watchdog, alongside TSan/ASan builds of the whole
  suite.
- **`make selfhost`** — the differential gate for Chapter 17: compiler-shaped programs must
  produce byte-identical output from the C compiler and the Ember-written one.

`make verify` runs the core of them in one command, and CI runs the gate on every push — on
Linux *and* macOS, a decision whose recorded reasoning is asymmetry: a macOS-ism that breaks
Linux is invisible on the machine the author is sitting at, so only a standing Linux job can
stop the port from bit-rotting.

The unglamorous parts carry the philosophy. The baselines (`crucible-known.txt`,
`ceilings-known.txt`) mean a gate is *ratcheted*: known findings don't nag, new ones fail loudly.
The generated programs print **checksums** of everything they touch, so a wrong *answer* — not
just a crash — trips the differential. And the shrinking means a 3 a.m. failure arrives as a
minimal reproducer, not a haystack. The architecture log states the ambition plainly: turn the
recurring bug classes into build-time failures, so the language proves its own safety instead of
its users discovering the holes.

> **In plain terms.** Beyond ordinary tests, this project keeps a set of tireless adversaries on
> the payroll: one invents thousands of memory-torture programs nightly and checks them five
> different ways; one tries to overflow every internal limit; one verifies the machine code's
> plumbing byte by byte; one tries to fool the leak-detector in both directions. Each adversary
> was hired after a real bug of its kind slipped through once. They run on every change, they
> only complain about *new* problems, and when they do complain they hand you the smallest
> program that reproduces the issue.

> **Machine-room trivia.** The Linux port paid for itself on arrival: gcc's
> `-Werror=format-truncation` — a warning Apple's clang doesn't emit — flagged a 24-byte buffer
> that was genuinely truncating a generated C identifier. A real latent miscompile, caught not by
> a test but by the *second compiler's pickier eyes*. Differential everything, including your
> toolchain.

---

## Chapter 15 — One Frontend, Many Faces

Here is a question that quietly decides whether a young language's editor support lives or dies:
*when your editor shows a type on hover, whose analysis is it showing?* The cautionary tale is
rust-analyzer — a heroic, separate reimplementation of Rust's frontend that the Rust team itself
describes as an unsustainable maintenance burden. Every language server that stayed healthy
(clangd, gopls, tsserver) shares its compiler's actual frontend. Ember's
[architecture decision](architecture.md) draws the conclusion without drama: the language server
**is the compiler** — `emberc --lsp`, same binary, same lexer, parser, and checker, speaking
JSON-RPC over stdio. The error-tolerant parser (Chapter 5) and structured diagnostics (Chapter 8)
weren't retrofits for the editor; they were already requirements of the LLM loop, which is why
the LSP could exist at all.

The bridge between "the checker knows everything" and "the editor can ask" is the **semantic
index** ([`include/semindex.h`](https://github.com/kmcnally5/ember-lang/blob/main/include/semindex.h)):
a position-keyed table the checker fills *as it resolves*, recording for each identifier
occurrence what it resolved to, its rendered type, its documentation, and where it was defined.
The entry an editor's question lands on:

```c
typedef struct {
    int     line;        // 1-based line of the identifier
    int     col;         // 1-based start column
    int     end_col;     // 1-based column just past the identifier (exclusive)
    SemKind kind;        // what this identifier denotes (drives the hover prefix)
    char   *type;        // rendered type, e.g. "int", "[string]", "Point" (owned, may be NULL)
    char   *detail;      // a one-line hover signature, e.g. "let x: int" (owned, may be NULL)
    char   *container;   // owning module alias ("ui") or type ("Point"), or NULL (owned)
    char   *doc;         // the symbol's /// doc comment, or NULL (owned)
    char   *value;       // a constant's literal value ("0xE63946"), or NULL (owned)
    int     byte_offset; // field byte offset within its struct, or -1 (n/a)
    int     byte_size;   // field/type byte size, or -1 (n/a)
    char   *def_file;    // definition's file, or NULL = same file as the reference (owned)
    int     def_line;    // definition site line, or 0 when unknown
    int     def_col;     // definition site column, or 0 when unknown
    char   *ref_file;    // file THIS occurrence is in (for cross-file references), or NULL (owned)
} SemEntry;
```

The index is opt-in — batch compiles pass `NULL` and pay nothing — and almost every editor
feature reduces to "look up the position, read the entry": hover, go-to-definition, completion,
find-references, rename, semantic highlighting, inlay hints. The principle the docs repeat is
*record at the resolution site*: the checker already did the work; the index just stops the
answers being thrown away. (Note `byte_offset` and `byte_size` on fields — hover a struct field
in Ember and your editor tells you its memory layout, because the checker genuinely knows.)

Some of the surrounding decisions show how much craft hides in "editor support":

- **Diagnostics are check-only.** The LSP's error pass runs load + type-check with no codegen —
  so the dependency-free default build can correctly analyse a graphics program it could never
  *run*. Graphics **signatures** compile into every build; only the implementation is gated.
  Before that split, opening a UI example produced 182 false errors (OFI-078). After: zero.
- **Columns are honest.** The compiler counts columns in bytes; the LSP protocol defaults to
  UTF-16 code units. The server negotiates `positionEncoding` (utf-8 when the client offers it,
  translation otherwise), because one non-ASCII character in a comment shifting every hover on
  the line (OFI-075) is precisely the kind of wrongness a tool must not have.
- **The prover reaches the editor.** Each `ensures` clause carries an inlay verdict — `✓ proved`
  or `○ runtime-checked` — from the same prover `--emit=prove` runs (Chapter 13), and code
  actions scaffold new contract clauses. The verification loop, surfaced where code is written.
- **`emberc --doctor`** exists because setup friction kills young languages: it checks the
  binary, the stdlib path, the frontend's health, and — the sly one — whether the *installed*
  binary your editor launches matches the one you just built, printing `[ok]`/`[!!]` lines with
  the exact fix for anything wrong.

Chapter 4 promised the single-source-of-truth discipline was a family; here is the reunion.
The lexical vocabulary lives once (`vocab.def` → lexer, LSP hovers, editor grammars, with a
build-time sync check). The instruction set lives once (`opcode.h` → codegen, VM, disassembler,
codec). Type rendering lives once (`src/typefmt.c` — the hover card and the generated docs are
byte-identical because they are the same function). Doc comments live once (lexer → AST → hover
*and* `--emit=docs`). The version string lives once (`include/version.h` → `--version`, `--help`,
the LSP's `serverInfo`, the doctor's staleness check). None of this is glamorous; all of it is
why the tooling tells one coherent story.

> **In plain terms.** The thing that powers your editor's tooltips *is the compiler itself*, kept
> honest by construction: there is no second, slightly-different brain to drift out of sync. As
> the compiler checks your code it fills in a lookup table — "this name, at this spot, is that
> thing, of this type, documented so" — and every editor feature is just a read from that table.
> Even the proof results land in the margins of your editor, and a built-in `--doctor` will tell
> you exactly which part of your setup is misbehaving and how to fix it.

> **Machine-room trivia.** The doctor's staleness check exists because of the most macOS bug in
> the log (OFI-040): copying a new binary *over* an old one keeps the file's inode, the kernel
> compares the new bytes against a signature cache keyed by that inode, and your freshly-built
> compiler is killed on launch — "Killed: 9", no explanation. The fix is enshrined in `make
> install`: delete first, then copy. Never overwrite a signed binary in place.

---

# Part V — The Edges

## Chapter 16 — Talking to C

Every self-respecting systems language eventually has to shake hands with C, and the handshake is
where guarantees traditionally go to die. Ember's design puts the entire negotiation behind one
visible door: an `extern "c"` block declaring the C-side signature in ordinary Ember syntax. There
is no `unsafe` keyword anywhere in the language — **the extern declaration is the trust
boundary**. The signature you write is the contract the checker enforces; whether it matches the
real C function is the one place Ember's guarantees stop, and the language makes sure that place
is greppable.

Behind the door, dispatch goes through an in-tree **registry** of typed wrappers
([`src/cextern.c`](https://github.com/kmcnally5/ember-lang/blob/main/src/cextern.c)) — no
`libffi`, no `dlopen`, the empty-dependency-tree principle holding even here. The interesting
problem is marshalling, and the header's own comment states the solution better than a paraphrase
could — from [`include/cextern.h`](https://github.com/kmcnally5/ember-lang/blob/main/include/cextern.h):

```c
// The boundary is defined by the **leaf scalar sequence**: a struct argument is flattened to its
// scalar leaves on the Ember side (it is held as a flat run of slots already — value-types), and
// the wrapper reassembles a *concrete C struct* from those leaves and passes it BY VALUE, so the
// system C compiler generates the platform's exact aggregate calling convention (the C ABI). A
// struct result is flattened back to leaves the same way.
```

That is the dependency-free way to get the C ABI *exactly right*: don't write an ABI layout
engine for every platform — hand a real C struct to the real C compiler and let it do the one
thing it provably knows. Ember's side of the boundary is just a flat sequence of scalar leaves,
each coded by a character: `'i'` and `'f'` for integers and floats, `'p'` for a string crossing
as `const char*`, `'b'` for a packed scalar array crossing as a buffer, `'P'` for an opaque
pointer Ember will carry but never look inside.

The ownership rule at the boundary is one sentence: **C borrows, for the duration of the call.**
Ember keeps ownership of everything it passes and frees nothing C owns; a `mut` buffer documents
that C writes in place; a C function that returns memory it allocated gets the `ret_is_string`
treatment — Ember copies the bytes into a proper Ember string and frees the C allocation, so
foreign memory never leaks into the ownership model.

Opaque handles get the strictest deal of all, because Ember cannot see inside them. A `Ptr`
(think `FILE*`, a database connection) is **linear**: the checker proves it is consumed *at most
once* — the closing call takes it by `move`, so use-after-close is a compile error — and *at
least once* — a handle that can reach any scope exit unclosed, on any path, is also a compile
error, via the AND-merge dataflow from Chapter 7. Double-close and leak, the two oldest FFI
footguns, are unrepresentable at zero runtime cost. The compile-time-only choice is itself
recorded (a destructor would mean Ember guessing how to free a foreign handle; it refuses to
guess), and the Ledger gate (Chapter 14) fuzzes the analysis from both sides. The
[`std/http`](http-design.md) streaming design shows the pattern at its best: a `curl` handle
lives behind `open → next → next → close(move h)` on a worker fiber, and the compiler holds the
worker to the close.

One boundary, two mechanisms, since the kernel work (2026-07-01): a name the registry doesn't
know is a **direct extern** — the native backend forward-declares it with its exact C type and
emits a direct call for the linker to resolve, params and return restricted to scalars and
`Ptr`. That is the door to bare metal (next chapter). The VM, which cannot call an arbitrary
symbol, rejects such programs with a clear "build native" message — a smaller door, honestly
labelled, rather than a broken promise.

> **In plain terms.** Calling C is allowed, visible, and fenced: you declare the foreign function
> once, in one recognisable block, and that declaration is the exact edge of Ember's guarantees.
> Data crossing the border is lent, never given away; anything C hands back gets copied into
> Ember's world; and a foreign resource like an open file must provably be closed exactly once on
> every path through your code, or the program does not compile.

> **Machine-room trivia.** The FFI wrapper ABI is deliberately context-free — a C function
> pointer taking values in, values out, with no access to the Ember runtime. That austerity is
> load-bearing: it is *why* an extern can never touch a channel, which forced the streaming HTTP
> design into the pull-handle-plus-fiber shape — concurrency stays entirely on Ember's side of
> the border, where the scheduler and the ownership rules can see it.

---

## Chapter 17 — The Compiler That Eats Itself

Two campaigns are running as this book is written, and they share a purpose: prove the language
is real by making it carry serious weight. One rewrites the compiler in Ember. The other boots
Ember on bare metal.

**Self-hosting** lives in
[`selfhost/`](https://github.com/kmcnally5/ember-lang/blob/main/selfhost) and proceeds stage by
stage — lexer, parser, checker, codegen, and now the native C emitter, each a fresh Ember program
(`lexer.em`, `parser.em`, `checker.em`, `codegen.em`, `cgen_c.em`) ported from its C counterpart.
The discipline is the same differential religion as everywhere else: the C compiler — frozen and
reproducible-from-zero as the git tag `stage0-v0.3.42` — is the oracle, and `make selfhost`
demands the ported stage produce **byte-identical output** to it (the suite stood at 1209
selfhost checks passing when OFI-168 closed). The freeze itself got an architecture decision: a
tagged *source* commit rather than a vendored binary, because binaries rot and a
no-dependencies C tree builds anywhere, forever. A self-hosted language that can no longer be
rebuilt without itself is a trap the project refuses in writing — and the eventual
stage-1-compiles-stage-2-identically demonstration (the *Trusting Trust* construction) is
described, carefully, as "a property to demonstrate, not a security claim."

The port earns its keep by what it flushes out. Writing a compiler is the most demanding program
the language has ever hosted, and three OFIs opened during the port are exactly the kind of
subtle it finds: a generic payload-binding inference gap (OFI-163), a missing owning-temp drop in
method-call arguments, caught because one emitted instruction shifted every downstream byte
offset (OFI-165), and the gcc-vs-clang operand-evaluation-order divergence (OFI-166) from
Chapter 11's trivia box. Dogfooding at this intensity is a search strategy.

**Bare metal** lives in
[`kernel/`](https://github.com/kmcnally5/ember-lang/blob/main/kernel), and milestone 1 shipped
the day this book is dated: a heap-free Ember `main`, compiled with `--emit=c --freestanding`,
linked against a boot stub (`boot.S`), a linker script, and a tiny runtime shim — booting on
QEMU's aarch64 `virt` machine and writing `Hello from Ember!` to the UART. `make test-kernel`
boots it and checks the output, because of course the kernel has a regression test. The recorded
rationale for the whole native road (Chapter 11) ends here: *you cannot run an OS as a guest
inside a VM that itself needs an OS.* The enabling piece was Chapter 16's direct extern —
`uart_putc` is just an `extern "c"` function the linker resolves against the shim — and the
stated endgame is MMIO intrinsics (volatile load/store, no C shim at all), sitting openly on the
ledger as deferred work.

Neither campaign is finished, and the book won't pretend otherwise. What they already demonstrate
is the method: pick a goal that cannot be faked, wire a differential or a boot test that defines
success mechanically, and let the attempt file OFIs against the language until it works.

> **In plain terms.** The team is rewriting Ember's compiler *in Ember*, piece by piece, with a
> rule that each piece must produce output identical to the original down to the last byte — the
> most honest test a language can take, and one that has already caught real bugs. Meanwhile a
> tiny Ember program now boots directly on (virtual) hardware with no operating system
> underneath and says hello over the serial port. Both are early; both are the kind of early you
> can verify.

> **Machine-room trivia.** The kernel milestone found a compiler bug the same day it shipped —
> indirectly. The adversarial review of the direct-extern work asked "what happens if someone
> uses a foreign function as a *value*?" — `let f = uart_putc` — and the answer was a segfault
> that had been lurking for *every* extern all along (`sin` crashed identically). Filed as
> OFI-168, rejected cleanly now. Reviews here interrogate the neighbours, not just the change.

---

## Chapter 18 — The OFI Ledger

If this book had to save one file from the repo to explain how the project works, it would not be
the parser. It would be [OFI.md](OFI.md) — the *Opportunities For Improvement* log, which the
working agreement wires into daily practice with one rule: when you find a bug, a design flaw, or
an inconsistency with the manifesto, **you don't code around it — you number it.** `OFI-NNN`, a
date, what's wrong, and eventually a disposition. Ids are never reused and never renumbered;
closed items keep their post-mortems forever. At the time of writing the ledger runs past
OFI-168.

The mechanics are simple and load-bearing. The file opens with a status paragraph — a captain's
log entry, currently beginning *"nothing on the critical path"* — followed by an index table,
newest first, each row carrying its disposition: **OPEN**, **CLOSED**, or **PARTIAL**. Open items
get full write-ups; the remaining-open set is sorted, in the file itself, into honest buckets:
deliberate deferrals, measure-first performance questions, and accepted edges — including
outright *wontfix*s whose reasoning is recorded (a cross-thread-free trade-off, accepted;
a lifetime-inference tail, deferred with its design notes). "We know, we chose, here's why" is a
different thing from a bug tracker's silence, and the difference is the culture.

A close note here is not "fixed." Pull one, nearly at random — OFI-150, refinement types:
*"421/0, 7 gates, ASan; a 4-bug adversarial pass (3 from the review + a multi-slot-sibling
soundness gap I caught) all fixed."* The golden count at close, the gates run, the sanitizer
state, and the review's findings — evidence attached to the claim, every time. The reviews
themselves are a standing practice with a house name for the big ones: multi-agent adversarial
panels (five perspectives for the `Ptr` linearity design; fourteen for `rc struct`'s soundness
argument, which reduced eight attempted smuggling vectors to the final two rules), plus
pre-mortems — the "chocolate-teacup check" — before major features, one of which reshaped the
whole capability-system plan and is written up in the manifesto as such.

Read enough entries and you notice the ledger's real function: it is where pain is converted into
structure. A one-off mistake stays an anecdote; a *numbered* mistake becomes a class, and classes
get gates (Chapter 14), conventions (Chapter 6's zeroing rule), or architecture decisions
(Chapter 9's LEB128). The chapters of this book have been quietly citing that conversion all
along — OFI-033 became the vocabulary file, OFI-040 became an install rule, OFI-049 became a
type-system feature and a fuzzer, OFI-056 became an encoding. The ledger is the project's memory,
and its unusual honesty is not a virtue bolted onto the engineering; it *is* the engineering.

> **In plain terms.** Every flaw found in Ember gets a permanent numbered file: what was wrong,
> what was decided, what proved the fix, all kept even after it's resolved — especially after.
> Claims of "fixed" arrive with their test counts attached, big designs get formally attacked by
> panels of reviewers before they ship, and problems the team has decided *not* to fix are
> written down with reasons rather than left to be rediscovered. It reads less like a bug tracker
> and more like a ship's log, and it's the best single window into how the whole thing is built.

---

## Chapter 19 — A Reader's Guide to the Source

This book has quoted the compiler all the way through; this chapter hands you the keys. Sizes are
as measured on 1 July 2026 — they will drift, but the *proportions* are the lesson.

| File | Lines | What it is |
|------|-------|------------|
| `src/check.c` | 8,981 | The type checker — types, ownership, generics, linearity (Ch. 7) |
| `src/vm.c` | 5,003 | The bytecode VM, fibers, faults-at-runtime (Ch. 10) |
| `src/cgen_c.c` | 3,830 | The native AST→C backend (Ch. 11) |
| `src/codegen.c` | 2,798 | AST→bytecode lowering (Ch. 9) |
| `src/lsp.c` | 2,518 | The language server (Ch. 15) |
| `src/runtime.c` | 2,246 | The runtime library native binaries link (Ch. 11) |
| `src/parser.c` | 1,999 | Recursive descent + precedence climbing (Ch. 5) |
| `src/graphics.c` | 1,388 | The opt-in raylib/FreeType backend |
| `src/main.c` | 1,081 | The driver: flags, `--emit` modes, module loading |
| `src/cextern.c` | 735 | The FFI registry and wrappers (Ch. 16) |
| `src/json.c` | 560 | The in-tree JSON reader |
| `src/ast_print.c` | 521 | `--emit=ast` (Ch. 5–6) |
| `src/lexer.c` | 504 | The scanner (Ch. 4) |
| `src/prove.c` | 465 | The Fourier–Motzkin contract prover (Ch. 13) |
| `src/diag.c` | 209 | Diagnostics, human and JSON (Ch. 8) |
| `src/fault.c` | 185 | The Fault renderers (Ch. 8) |
| `src/docgen.c` | 179 | `--emit=docs` |
| `src/chunk.c` | 163 | Bytecode chunk plumbing (Ch. 9) |
| `src/arena.c` | 94 | The allocator everything lives in (Ch. 6) |
| `src/semindex.c` | 91 | The semantic index (Ch. 15) |

(Plus the small change: `token.c`, `opcode.c`, `trace.c`, `typefmt.c`, `builtin.c`, `program.c`,
`jsonw.c` — all under a hundred lines each, all exactly what their names say.) Headers live in
[`include/`](https://github.com/kmcnally5/ember-lang/blob/main/include), and several are
first-class reading: `ast.h` (610 lines — the language's whole shape), `opcode.h` (208 — the
instruction set and its X-macro), `vocab.def` (135 — the vocabulary), `value.h`, `fault.h`,
`trace.h`, `semindex.h`.

**A first sitting** that works, in reading order: `include/vocab.def` (ten minutes, meet the
language), then `include/token.h` and `src/lexer.c` (a scanner you can hold in your head), then
`src/arena.c` (94 lines, the memory model), then `include/ast.h` alongside
`tests/parser/expressions.ast` (the shapes, with worked answers), and finally `src/parser.c`
top to bottom. That is the whole frontend, one evening, no heroics. Save `check.c` for a second
sitting and enter it by feature — pick "slices" or "newtypes," grep the OFI number, and read the
one campaign's code with the log entry beside it, which is how the file was written in the first
place.

**The proof of every claim** is under
[`tests/`](https://github.com/kmcnally5/ember-lang/blob/main/tests): `run/` (execution goldens),
`lexer/`, `parser/`, `codegen/` (stage goldens — this book's exhibits), `native/` (the VM↔native
differential), `check/`, `fault/`, `trace/`, `replay/`, `parallel/`, `selfhost/`, and the
runners beside them. The examples in
[`examples/`](https://github.com/kmcnally5/ember-lang/blob/main/examples) are documentation that
must also compile — the suite enforces that (a lesson recorded as OFI-030, after two showcase
files silently rotted).

**House rules**, if you touch anything: C17 under `-Wall -Wextra -Werror`, no undefined
behaviour, no third-party dependencies without sign-off. Discuss language design before
implementing it, and trace the decision to the manifesto or amend the manifesto out loud. Every
feature lands through the whole pipeline with tests, or it isn't done. Found a flaw? Number it.
And mind the blank lines — five between functions in the sparse files, two in the
comment-per-function ones (OFI-144; yes, really; Chapter 2 warned you the whitespace has a paper
trail).

For the user-facing view of the same machine — every `make` target, every flag, the whole
toolbox — Firelight's [Chapter 21](THE_EMBER_BOOK.md#chapter-21--the-whole-toolbox) has you, and
[start.md](start.md) gets a first program running in minutes.

> **In plain terms.** The compiler is about thirty-five thousand lines of C, and its anatomy
> matches this book's chapters closely enough that you can go from any chapter straight to the
> file it describes. If you read code at all, there is a genuine one-evening path through the
> entire frontend — few production compilers can honestly offer that.

---

# Colophon

*Ember from the Inside* was written on 1 July 2026, against the Ember tree as it stood that day
(the day kernel milestone 1 landed, for those keeping score at home).

**How this book was verified, exactly.** Every C excerpt was copied byte-for-byte from the cited
file and re-checked against the tree after the final edit. Every compiler output shown is a
golden file from `tests/` — an artifact the project's own `make test` regenerates and enforces —
quoted verbatim and named where it appears. Every Ember sample is an excerpt of a file in
`tests/` or `examples/` that the suite compiles as part of its normal run. The author of this
book did not run the compiler while writing it (the tree was busy being worked on, and a book
should not jostle the workbench); the samples' compile-and-run guarantee is therefore exactly as
strong as the test suite's — which is the stronger of the two guarantees on offer, and the same
one the rest of the documentation leans on. If a future edit adds a sample from anywhere other
than the suite's files, it owes the reader a fresh compile first; that is this book's contract,
as Firelight's is its own.

**What will go stale first.** Line counts (Chapter 19), the golden tally (428), the open/closed
state of any OFI named here, and the gated status of the M:N scheduler. The *shapes* — the
pipeline, the single-source-of-truth tables, the gates, the ledger habit — are the durable part;
when they change, the OFI log and [architecture.md](architecture.md) will say so before this book
does.

**Changelog.**
- *2026-07-01* — First edition: Parts I–V, nineteen chapters and this colophon.

The language, meanwhile, keeps moving. Mind the sparks.





