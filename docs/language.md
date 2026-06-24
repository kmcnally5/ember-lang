---
title: Language Reference
nav_order: 3
description: The canonical syntax and semantics reference for Ember — a statically-typed, brace-delimited systems language that is memory-safe without a garbage collector and compiles to C.
---

# The Ember Language Reference

The canonical *how-to-write-Ember* document. It is a **living reference**: it describes only
what the language has actually grown to, and every feature slice updates it in the same commit.
For the *why* behind the design see [../MANIFESTO.md](../MANIFESTO.md); for runnable samples see
[../examples/](../examples/).

> **Audience note.** Ember is designed LLM-first (MANIFESTO §5b). This reference is the single
> source a model should rely on. Where a construct is designed and parses but does not yet
> execute, that is stated plainly — do not assume unmarked behaviour.

---

## Implementation status

Ember is built as a *walking skeleton*: the whole pipeline (lex → parse → type-check → bytecode
→ VM) exists, and language features are switched on one slice at a time, end to end. So three
layers of "exists" are worth separating:

| Layer | Meaning |
|-------|---------|
| **Runs** | Compiles to bytecode and executes on the VM. |
| **Parses** | The grammar accepts it and builds an AST (`--emit=ast`), but it is not yet type-checked or executed. |
| **Designed** | Specified here and in the manifesto/examples; not yet in the grammar or only partially. |

**Runs today:** functions; `int` and `bool` values (`true`/`false`); integer arithmetic
(`+ - * / %`, unary `-`); comparison (`== != < <= > >=`); short-circuiting logical `&&`/`||`
and `!`; **bitwise and shift operators** (`& | ^ ~ << >>`, integer-only, width-aware); `let`/`var` bindings (int or bool) with reading, assignment to `var`, and immutability
enforcement on `let`; `if`/`else` (with **strict bool conditions** — no truthiness);
`loop`/`break`/`continue`; **multiple functions, calls, parameters, and recursion**;
**`int`, `float`, and `string` values** (overflow-trapping integer arithmetic, no implicit
coercion, `+` concatenates strings); the **full explicit-width numeric family** (`i8 i16 i32 i64`,
`u8 u16 u32 u64`, `f32 f64` — width-checked arithmetic, unsigned `u64`, `f32` rounding,
suffix/inference literals, `u8(x)`-style conversions); **`struct` types — construction, field reads, and methods
(with `self`), including struct-typed fields**; **`interface` declarations with `implements`
conformance checking**; **`enum` types and exhaustive `match`** (variant construction + field
binding + a `case _` catch-all); a growing **standard library** — I/O (**`print`/`println`**, **`read_line`/`read_file`/`write_file`**), program environment (**`args`/`env`/`exit`**),
math (**`sqrt`/`pow`/`abs`/`floor`/`ceil`/`round`/`random`**), strings (**`to_upper`/`to_lower`/`trim`/`contains`/`index_of`/`starts_with`/`ends_with`/`repeat`/`substring`/`replace`/`join`**, plus code-point caret helpers **`cp_count`/`cp_at`/`cp_slice`/`cp_prefix`/`cp_insert`/`cp_delete`** — Unicode-aware, written in Ember in **`std/string`**, `import`ed), a **`std/map`** generic hash map `Map<K, V>` and **`std/set`** hash set `Set<K>` (any `Hash + Eq` key),
and **`to_float`/`to_int`**, **`char_code`/`from_char_code`/`parse_float`**, **`clock()`** — and **expression statements**;
**generic structs
and enums, functions, and methods** (`Box<T>`, `Option<T>`, `Result<T, E>`, `fn id<T>(…)`,
erased, with type-argument inference) **including interface bounds** (`fn max<T: Ord>(…)`, with
witness dispatch); **first-class functions and closures** (`fn(T)->R` types, named functions as
values, `|x| x + n` lambdas that capture by value, generic HOFs — a **`std/list`** with generic
`map`/`filter`/`reduce`/`sort`); a **prelude** providing `Option<T>`/`Result<T, E>`
to every program; the **`?` operator** (error propagation on `Result`/`Option`); **field
mutation** (`p.x = v` through a `var`/`mut` place); and **ownership safety** — `move`/`mut`/
borrow parameters with sound move-tracking (use-after-move, no escaping borrows, no aliased
mutation); **deterministic memory reclamation without a GC** (structs and arrays freed at scope
exit; strings and enums reference-counted); **mutable, growable arrays** (`[T]` literals,
indexing, `a[i] = v`, `a.append`/`a.remove_last`/`a.remove_at`/`a.len`, scalar elements stored in **packed
native buffers**) and **`for … in`** iteration over arrays and **integer ranges** (`for i in
0..n`, both lowered to fused single-opcode loop steps); **string
interpolation** (`"{ expr }"`) and **UTF-8 string methods** (`len`/`bytes`/`char_count`/`chars`/`split`/`parse_int`);
**structured concurrency**
(`nursery`/`spawn` + typed `Channel<T>` with `send`/`recv`/`close`, where `recv` yields
`Option<T>`, on green threads); **modules** (`import "path" as name` with
module-qualified function calls + types, with `_`-prefix privacy); **executable contracts**
(`requires`/`ensures` with `result`, type-checked always, runtime-checked in debug and elided in
`--release`, reporting violations as structured events on the tape); and `return`. Run a program
with `emberc --emit=run file.em`.

**Interfaces** are fully runtime now: as **generic bounds** (`<T: Ord>`, static witness dispatch)
and as **value types** (`let s: Shape = …`, `[Shape]`, dynamic dispatch through a boxed
`{receiver, vtable}` — object-safe interfaces only). See [Interfaces](#interfaces-and-implements-conformance).

Everything below is marked **[runs]**, **[parses]**, or **[designed]** accordingly.

---

## Lexical structure

### Comments
Line comments only, `// to end of line`. **[runs]**

A comment that begins with exactly three slashes — `/// to end of line` — is a **doc comment**.
Placed on the line(s) immediately before a declaration (a `fn`, `struct`, `enum`, `interface`,
`let`/`var`, a struct field, a method, or an enum variant), it documents that declaration:
consecutive `///` lines coalesce into one Markdown block. Doc comments are not discarded like
ordinary `//` comments — they are attached to the declaration in the AST and become the single
source of API documentation, surfaced two ways from the one comment:

- the language server shows them on **hover** and in **completion** (`emberc --lsp`), and
- `emberc --emit=docs <file.em>` renders them to a Markdown reference page.

So a comment written once is both the editor tooltip and the docs, and the two cannot drift.
`////` (four or more slashes) and `//` are ordinary comments and are ignored. **[runs]**

```ember
/// A 2-D point in the plane.
/// Copied by value.
struct Point {
    /// The horizontal coordinate.
    x: int
    y: int
}
```

### Statement termination — newlines are significant
Ember has **no semicolons**. A newline ends a statement *only* when the line's last token can
end one (an identifier, a literal, `)`, `]`, `}`, `?`, or `return`/`break`/`continue`). After a
token that implies more to come — an operator, `,`, `(`, `=`, `->`, `&&`, … — the newline is
ignored, so multi-line expressions read naturally. **[runs]**

```ember
let total = a +      // line continues: trailing '+' suppresses the break
            b
```

The same rule governs **method chains**: split *after* the dot, not before it.
`value.<newline>method()` continues onto the next line, but `value<newline>.method()`
does **not** — the first line already ended, so the leading `.` is a syntax error. (This is
the opposite of Swift/JS leading-dot chaining; the trailing operator is what carries the line on.)

### Identifiers & keywords
Identifiers match `[A-Za-z_][A-Za-z0-9_]*`. Reserved words:
`let var fn return struct enum interface implements match case if else for in loop break continue
nursery spawn move mut self true false import as requires ensures extern`. The type names `int`, `float`, `string`,
`bool`, and `Self` are ordinary identifiers resolved in type position, not keywords.

### Literals
- **Integers** — `0`, `2026`. **[runs]**
- **Floats** — `3.14`, `0.0` (a `.` is only a decimal point when followed by a digit, so
  `obj.field` is never a float). **[runs]**
- **Strings** — `"..."`, with escapes `\n \t \r \\ \"`. `+` concatenates and `==`/`!=` compare
  by content. **Interpolation** splices an expression into a literal with `{ … }` — the hole
  holds any expression — including one with its own string literals, written with plain quotes
  (`"{a.split(",")}"`) — rendered to a string (int / float / string / **bool** holes, a bool as
  `true`/`false`) and concatenated. Write `\{`/`\}` for a literal brace. Strings are **UTF-8**. **Methods** split along that line — byte
  level for storage/FFI, code-point level for text: **`s.len()`** (byte count, O(1)),
  **`s.bytes()`** → `[u8]` (raw bytes), **`s.char_count()`** (Unicode code points, O(n)),
  **`s.chars()`** → `[string]` (one string per code point, UTF-8 decoded), **`s.split(sep)`** →
  `[string]` (byte-based but UTF-8-safe — the encoding is self-synchronizing), and
  **`s.parse_int()`** → `Option<int>` (`None` on empty/malformed/out-of-range; resolves the
  program's own `Option`, like `recv`). Invalid UTF-8 decodes leniently to U+FFFD. **[runs]**
- **Booleans** — `true`, `false`. **[runs]**

### Operators & precedence
Lowest to highest binding; all binary operators are left-associative:

| Prec | Operators |
|------|-----------|
| 1 | `\|\|` |
| 2 | `&&` |
| 3 | `\|` (bitwise or) |
| 4 | `^` (bitwise xor) |
| 5 | `&` (bitwise and) |
| 6 | `==`  `!=` |
| 7 | `<`  `<=`  `>`  `>=` |
| 8 | `<<`  `>>` (shift left / right) |
| 9 | `+`  `-` |
| 10 | `*`  `/`  `%` |
| (prefix) | `!x`, `-x`, `~x` (bitwise not) |
| (postfix) | `f(...)` call, `a.b` field/method, `a[i]` index, `e?` try |

Arithmetic, comparison, short-circuiting logical, and **bitwise/shift** operators (on the
appropriate types) **[runs]**; postfix forms (call / field / index / `?`) **[parses]**. Strict
typing applies: arithmetic needs a number, logical needs `bool`, bitwise/shift need integers,
`==`/`!=` need matching types, and there is no coercion (`1` is not a truth value).

The precedence mirrors C exactly, so `a & b == c` is `a & (b == c)` — parenthesize mixed
bitwise/comparison as you would in C. `&`/`\|`/`^`/`~`/`<<`/`>>` are **bitwise operators on
integers**, not reference or ownership sigils (Ember has none — ownership is keyword-based, §5b).
A single `\|` is also the lambda delimiter (`\|x\| x + 1`); grammar position disambiguates it from
bitwise-or. Shifts are bit operations: the value truncates to its operand width and the shift
amount must be in `[0, width)` (a trap otherwise); `>>` is arithmetic (sign-preserving) on signed
types and logical (zero-filling) on unsigned ones; `~` on a narrow unsigned type masks to its width.

---

## Bindings & mutability — [runs]

`let` introduces an **immutable** binding; `var` a **mutable** one. Two distinct keywords, each
one token (MANIFESTO §5b).

```ember
let name = "Ember"   // immutable
var count = 0        // mutable
count = count + 1    // OK
```

Assigning to a `let` is a **compile error** — this is enforced today:

```ember
let a = 5
a = 6   // error: cannot assign to an immutable 'let' binding; declare it with 'var'
```

Type annotations are optional on bindings (`let year: int = 2026`) and inferred when omitted.
A binding's initialiser is checked *before* the name is in scope, so `let a = a` refers to an
outer `a`, never itself.

A **top-level `let`** declares a module **constant** — a named, immutable, compile-time value
(`let WIDTH = 800`, `let TITLE = "ember"`). Its initialiser must be a literal (int, float, bool,
string, or a negated number); each use is substituted with that value at compile time, so a
constant has no runtime cost. Constants are exported like functions and read qualified across
modules (`draw.RED`); a leading `_` keeps one private (§5d). A top-level `var`, or a non-literal
initialiser (`let x = f()`), is not yet supported — general runtime/mutable globals are future
work; named compile-time constants are the common case (colors, key codes, limits, config).

---

## Functions — [runs]

```ember
fn add(a: int, b: int) -> int {
    return a + b
}

fn fib(n: int) -> int {
    if n < 2 { return n }
    return fib(n - 1) + fib(n - 2)   // recursion and forward references work
}

fn main() -> int {
    return add(fib(10), 1)           // => 56
}
```

A program is a set of top-level functions; execution starts at `main`. Parameter types are
mandatory and parameters are **immutable** bindings (reassigning one is an error). Calls are
checked for arity and argument types — no coercion. Recursion and forward/mutual references
resolve because all signatures are gathered before any body is checked. Execution today covers
`int`/`bool` parameters and return types; `self`/methods arrive with structs, and explicit
numeric widths with the value-model expansion.

A function may **omit `-> T`** entirely — it is then a **unit function**: it runs for effect
and produces no value (the foundation for concurrency workers). Inside one, a bare `return` is
allowed and `return <value>` is an error; the result of calling one cannot be bound (`let x =
tick()` is rejected, just like binding a `println`). `fn main()` may itself be unit — its
implicit result is `0`.

```ember
fn tick() {            // no `-> T` — a unit function
    println(99)
    return             // bare return is fine; falling off the end is too
}

fn main() {            // main may be unit; implicit result is 0
    tick()
}
```

---

## Contracts — [runs]

A function may carry **contracts**: `requires` preconditions and `ensures` postconditions, written
between the signature and the body (MANIFESTO §5e). A contract is an ordinary `bool` expression; an
`ensures` clause may name **`result`**, the return value. Any number of clauses, in any order.

```ember
fn clamp(x: int, lo: int, hi: int) -> int
    requires lo <= hi             // precondition: checked on entry
    ensures result >= lo          // postconditions: checked before every return,
    ensures result <= hi          // with `result` bound to the returned value
{
    if x < lo { return lo }
    if x > hi { return hi }
    return x
}
```

- **`requires`** is checked when the function is entered (the parameters are in scope); **`ensures`**
  is checked just before each `return`, with `result` bound to that value.
- A contract may call ordinary predicate functions, so the spec language *is* Ember: `requires
  is_sorted(xs)`. Contracts should read their inputs, not mutate them.
- On violation the program aborts with a clear error — `precondition failed in 'clamp' (requires,
  line 2)` — **and** emits a structured event on the execution tape (see *The execution tape*):
  `{"event":"contract_violation","fn":"clamp","detail":…,"stack":[…]}`. This is the point of
  contracts in an LLM-first language: a model writes the spec and the implementation separately,
  runs the program, and learns *exactly* which clause its code violated, on what values, as data it
  can act on.
- **Debug builds check contracts; a `--release` build elides them** (zero cost at runtime), the
  `debug_assert` model. Type-checking always runs — a non-`bool` contract is a compile error in
  every profile; only the runtime check is dropped. Contracts are enforced identically by the
  serial and the parallel runtimes (they are compiled into the bytecode).

```
emberc --emit=run         file.em     # debug: contracts checked (the default)
emberc --emit=run --release file.em   # release: contracts elided
```

### `assert` — inline checks that join the trace

`assert(cond)` (optionally `assert(cond, "message")`, where the message is a string literal) checks
a condition mid-function. Like a contract it lowers to the same checked instruction, so a failure is
not a bare crash but a structured trace event (`{"event":"contract_violation",…}`), and like a
contract it is **elided in `--release`**. The condition must be a `bool`. Use `assert` for the
invariants that hold *inside* a body; use `requires`/`ensures` for the function's boundary.

### Property-based checking — `emberc --emit=check` — [runs]

Contracts are an executable spec, so the compiler can **search for inputs that break them**. For
every *checkable* function — a free, non-generic function with at least one `ensures`, whose
parameters are each a scalar, an all-scalar struct, or an immutable-borrow array of full-width
scalars (`[int]`, `[f64]`, `[bool]`) — `--emit=check` generates many inputs that satisfy the
function's `requires`, runs it, and reports the first input that violates an `ensures`/`assert`
(or crashes) as a **counterexample**:

```
emberc --emit=check file.em
# check sum_pt: FAILED
#   counterexample: sum_pt({-1, 0})  =>  postcondition failed in 'sum_pt' (ensures, line 12)
# {"event":"check_failed","fn":"sum_pt","input":"sum_pt({-1, 0})","detail":…}
```

- **`requires` defines the domain.** Inputs that fail a precondition are out of scope — they are
  rejected and regenerated, never reported as failures.
- **Struct parameters are fuzzed field-by-field** and shown in brace form (`{-1, 0}`); nested
  all-scalar structs flatten into their leaves. **Array parameters** get a small random-length
  array and are shown in bracket form (`[-1]`).
- **Counterexamples are minimised (shrunk)** toward the simplest failing input — for arrays, by
  removing any droppable element and simplifying the rest — so you get `sum_pt({-1, 0})` and
  `total([-1])`, not the raw random values first found.
- **Generation is deterministic** (a fixed seed): the same counterexample every run, on every
  platform — suitable for golden tests and for an agent to reproduce.
- Each counterexample is also emitted as a machine-readable `check_failed` event, mirroring the
  contract trace. This is the verification loop (MANIFESTO §5j): a model writes code + a spec, and
  the language hands back a concrete, reproducible falsifying input.

### Deterministic record-replay — `emberc --emit=replay` — [runs]

A bug you cannot reproduce is a bug you cannot fix. Ember's nondeterminism comes from a small,
known set of sources — `random()`, the monotonic clock `clock()`, the external reads
`read_line()` / `read_file()`, and foreign (`extern "c"`) call results — so the runtime can
**record** every nondeterministic value a run consumes and **replay** them to reproduce that run
exactly. `--emit=replay` does this as a self-contained check: it runs the program twice — once
recording the nondeterministic draws, reads and C results (and buffering output), once replaying
them (performing no real I/O and no real foreign calls) — and verifies the two runs are
**byte-for-byte identical**:

```
emberc --emit=replay file.em
# replay: deterministic — 5 nondeterministic event(s) recorded (5 random, 0 clock, 0 read_line, 0 read_file, 0 ffi); both runs identical
# {"event":"replay","status":"deterministic","events":5,"random":5,"clock":0,"read_line":0,"read_file":0,"ffi":0}
```

The verdict is stable across invocations even though the underlying `random()`/`clock()` values,
external inputs, and C results differ every run — because replay feeds the *recorded* values back
(and re-reads/re-calls nothing), the program follows the exact same path. **Concurrency** is covered
for free: replay runs under the deterministic serial scheduler, so a `nursery`/`spawn`/channel
program replays byte-for-byte (the task interleaving is fixed, so its recorded draws line up). If the two runs disagree (`status":"diverged"`), the program has a source of
nondeterminism the runtime does *not* yet capture — which is precisely what this check surfaces.
Together with contracts and `--check`, this closes the verification loop (MANIFESTO §5j): a model
can write code, have it fuzzed against its spec, and replay any failure deterministically.

### Static contract proving — `emberc --emit=prove` — [runs]

Fuzzing can find a counterexample; **proving** establishes there is none. For contracts in a
decidable fragment — linear integer arithmetic over a function's integer parameters — Ember
discharges the proof statically, with no external solver. For each `ensures`, it substitutes
`result` with the body's returned expression and proves `requires ⟹ ensures` by showing
`requires ∧ ¬ensures` is infeasible (Fourier–Motzkin elimination; rational-infeasibility implies
integer-infeasibility, so a proof is sound):

```
emberc --emit=prove file.em
# prove add_nonneg: ensures @line 4 — PROVED          (a>=0 ∧ b>=0  ⊢  a+b >= 0)
# prove scale:      ensures @line 12 — PROVED          (x>=0         ⊢  2x   >= x)
# prove shift:      ensures @line 19 — not proved (use --check)
# proved 2 of 3 ensures clause(s); 1 to check
```

The prover is **sound, never optimistic**: anything outside the fragment (branches, nonlinearity,
`!=`/`||`, calls, non-integer parameters) or that it cannot discharge is reported as *not proved*
and deferred to `--check` — it never reports a false contract as proved. Proved postconditions need
no runtime check at all; the rest fall back to property-based fuzzing. This is the top of the
verification loop (MANIFESTO §5j): prove what is decidable, fuzz the rest, replay any failure.

---

## I/O and expression statements — [runs]

The built-ins **`print`** (no newline) and **`println`** (with a newline) write a single value
to standard output. They accept a number or a `string`. They are the first members of the
standard library and the seed of Ember's native-function mechanism.

Ember also reads from the world:

- **`read_line() -> string`** — one line from standard input, with the trailing newline removed
  (`\r\n` tolerated). Returns the empty string at end of input, so a read loop ends on `""`.
- **`read_file(path: string) -> string`** — the whole file as a string; the empty string if the
  file can't be opened (so missing files degrade gracefully rather than crashing).
- **`write_file(path: string, text: string)`** — write `text` to a file (creating/truncating it);
  a statement, like `print`.

```ember
fn main() -> int {
    write_file("/tmp/out.txt", "one\ntwo\nthree")
    let lines = read_file("/tmp/out.txt").split("\n")
    return lines.len()        // 3
}
```

And Ember talks to the **environment it was launched in**, so it can be a real command-line tool:

- **`args() -> [string]`** — the command-line arguments passed to the program (everything after
  the source file on the `emberc --emit=run file.em …` line). Empty when none were given.
- **`env(name: string) -> string`** — the value of an environment variable, or `""` if unset.
- **`exit(code: int)`** — terminate the program immediately with an exit code (`0` = success).
  Execution stops at the call; nothing after it runs and `main`'s return value is not printed.

```ember
fn main() {
    let names = args()
    if names.len() == 0 {
        println("usage: greet <name>...")
        exit(1)                                   // fail cleanly, like any CLI tool
    }
    var word = env("GREETING")
    if word == "" { word = "Hello" }
    for name in names { println("{word}, {name}!") }
}
```

`args()` and `env()` are part of the program's fixed invocation context, so record-replay
(`--emit=replay`) treats them as deterministic (it re-runs the same invocation), unlike `read_line`
/ `read_file` whose results it records.

A call used purely for its effect is an **expression statement** — a call on its own line, whose
result is discarded:

```ember
fn main() -> int {
    print("answer = ")
    println(6 * 7)        // answer = 42
    return 0
}
```

Only calls may be expression statements. `print`/`println` produce **no value**, so using one
where a value is expected (binding it, an operand, an argument) is a compile error.

A binding named **`_`** is a **discard**. `let _ = expr` evaluates `expr` and throws the result
away — like an expression statement, but for *any* value, not only a call — and unlike a normal
binding it may be **repeated** in the same scope and is **write-only**: `_` names nothing, so
reading it (`return _`) is an "undefined variable" error.

```ember
let _ = m.remove(key)     // ignore the "was it present" bool
let _ = m.remove(other)   // a second `_` in the same scope is fine
```

The discarded value is still managed correctly: an owned temporary (a fresh string, array, or
struct) is dropped exactly once, and a linear `Ptr` may **not** be discarded this way —
`let _ = fopen(…)` is the same "opened but not closed" error as any other un-consumed handle,
since a discard has no destructor to run. `_` is equally a stand-in for a value you don't need as
a **function parameter** or a **variant-pattern field** (`fn f(_: int, _: int)`, `case Some(_)`).

## Functions as values & closures — [runs]

Functions are first-class. A function **type** is written `fn(T, …) -> R` (the `-> R` is omitted
for a unit result), and a function used in value position — a named function, or a **lambda** —
has that type. So a function can be passed, stored, returned, and called like any value.

```ember
fn apply(f: fn(int) -> int, x: int) -> int { return f(x) }
fn double(x: int) -> int { return x * 2 }

fn main() -> int {
    let g = double            // a named function as a value
    let a = apply(double, 5)  // 10  — passed as an argument
    let b = g(7)              // 14  — called through a binding
    return a + b
}
```

**Lambdas** are `|params| expr` or `|params| { … }`. Parameter types are inferred from the
function type expected at the use site (or annotated, `|x: int| …`), and a lambda **captures**
the enclosing variables it uses — **by value**: it copies them into the closure when it is
created, so it never dangles and there is no escape analysis. (Capturing is read-only — a closure
can't reassign an outer variable.)

```ember
fn main() -> int {
    let n = 100
    let add_n = |x| x + n        // captures n by value
    let nums = [1, 2, 3]
    let total = reduce(nums, 0, |acc, x| acc + x)   // a lambda inline
    return add_n(5) + total      // 105 + 6
}
```

A function value is a heap **closure** (a code reference plus its captured environment),
reference-counted like a string. A bare named function is just a closure with no captures, so one
call mechanism serves both. A lambda must appear where a function type is expected, so its types
are known; `let f = |x| x + 1` on its own needs an annotation (`let f: fn(int) -> int = …`).

**Runs today:** function types; named functions and lambdas as values; capture-by-value; calling a
function value (including one returned from a call, `pick(c)(9)`); **generic higher-order
functions** — type arguments are inferred from array and function arguments, and a lambda passed
to one (`map(xs, |x| x * n)`) is checked once the other arguments pin the type parameters, its
result type inferred from its body. **Not yet:** capturing a struct or array (a by-value capture
of a unique owner would alias it — a clear compile error suggests passing it as a parameter).

## Standard library — [runs]

Beyond I/O, the standard library has two layers. A small set of **native primitives** (irreducible
operations implemented in C):

- **Math** (on `float`): `sqrt`, `pow(base, exp)`, `abs`, `floor`, `ceil`, `round`, and `random()`
  (a `float` in `[0, 1)`).
- **Characters & parsing**: `char_code(s) -> int` (the Unicode **code point** of `s`'s first
  character, `-1` if empty), `from_char_code(n) -> string` (UTF-8-encodes code point `n` to a 1–4
  byte string; out-of-range/surrogate → U+FFFD), `parse_float(s) -> float`.
- **Hashing**: `hash(s) -> int` — a non-negative FNV-1a hash of a string, the primitive `std/map`'s
  hash table is built on.
- **String building**: `concat(parts) -> string` — joins a `[string]` into one string in a single
  allocation and copy pass. Strings are immutable, so building one with repeated `out = out + c` is
  O(n²); `std/string`'s builders accumulate pieces in an array and `concat` once, staying linear.

On top of those, the rest of the library is **written in Ember itself** and lives in real source
files under `std/`, pulled in with an ordinary `import`. The `std/` prefix is **reserved**: it
resolves to the toolchain's standard-library directory (`$EMBER_STD`, else `<compiler>/../std`)
regardless of where the importing file sits. This is the model for growing the stdlib — write it
in Ember over a minimal native base, in a file, and `import` it like any other module.

- **`std/string`** — `to_upper`, `to_lower`, `trim`, `contains(s, sub)`, `index_of(s, sub)`
  (`-1` if absent), `starts_with(s, prefix)`, `ends_with(s, suffix)`, `repeat(s, n)`,
  `substring(s, start, end)` (half-open, bounds clamped), `replace(s, from, to)` (all
  occurrences), `join(parts, sep)` (the inverse of the `split` intrinsic). **Unicode-aware** — built
  over the UTF-8-decoded `chars()`, so these index by **code point**, not byte (only `s.len()` is
  bytes). Plus a code-point caret family for text editing: `cp_count(s)`, `cp_at(s, i)`,
  `cp_slice(s, a, b)`, `cp_prefix(s, n)`, `cp_insert(s, idx, ins)`, `cp_delete(s, idx)` — all with
  clamped, never-trapping indices.
- **`std/list`** — the generic functional toolkit over arrays: `map<T, U>(xs, f)`,
  `filter<T>(xs, keep)`, `reduce<T, U>(xs, init, f)`, `sort<T>(xs, less)`. Each takes a
  **function value** — a named function or a lambda (which may capture) — and the element types
  are inferred from the arguments: `list.filter(xs, |x| x > n)`, `list.map(words, |w| w.len())`
  (`[string]` → `[int]`), `list.reduce(words, "", |acc, w| acc + w)`,
  `list.sort(words, |a, b| a.len() < b.len())`.
- **`std/map`** — `Map<K, V>`, a generic hash map over **any key type** `K` that is
  `Hash + Eq` (built-in scalars and strings qualify natively; a user `struct` that
  `implements Hash, Eq` is a valid key too): `Map<string, int>`, `Map<int, bool>`,
  `Map<Point, V>`. Construct one as `Map<string, int> { buckets: [], count: 0 }`, then
  `m.set(key, val)`, `m.get(key) -> Option<V>`, `m.has(key)`, `m.size()`, `m.keys() -> [K]`
  (bucket order, not insertion order). Backed by an open-addressing hash table (linear probing,
  doubling at a 0.7 load factor), so lookups and inserts are amortised O(1). It is itself written
  in Ember — a generic struct bounded by `Hash + Eq`, dispatching the key's `hash`/`eq`
  through witnesses stored per instance. No `Copy` bound: a built-in key copies cheaply, and a
  move-type **struct key is deep-cloned structurally on store** (the runtime owns its copy, the
  caller keeps theirs — value-semantic keys, no `clone()` ceremony; OFI-042).
- **`std/set`** — `Set<K>`, a generic hash set over any `Hash + Eq` key — the same
  open-addressing table as `std/map`, storing keys only. Construct it as `Set<string> { slots: [],
  count: 0 }`, then `s.add(key)` (a duplicate is a no-op), `s.has(key) -> bool`, `s.size()`, and
  `s.items() -> [K]` (bucket order). Membership and insertion are amortised O(1).
- **`std/slotmap`** — `SlotMap<V>`, a generic **generational arena**: it owns the values and hands
  out small copyable `Handle`s (a slot index + a generation) instead of pointers, separating
  *identity* (the handle) from *ownership* (the store). Construct it as `SlotMap<V> { items: [],
  gen: [], free: [], count: 0 }`, then `a.insert(v) -> Handle`, `a.get(h) -> Option<V>`,
  `a.contains(h)`, `a.replace(h, v) -> bool` (overwrite a live slot, keeping the handle valid),
  `a.remove(h) -> bool`, `a.values() -> [V]`, `a.handles() -> [Handle]`, `a.size()`, `a.is_empty()`.
  Removing a value **bumps its slot's generation**, so every outstanding handle to it goes stale and
  reads back as `None` rather than a dangling value — the C raw-index footgun (a silent wrong-entity
  read after a slot is recycled, the ABA bug) becomes a safe `Option` by construction. Freed slots
  are recycled (reuse is O(1) via a free-list); a move-type `V` is **deep-cloned on store** like a
  `std/map` value, so the arena owns its copy. There is no in-place `get_mut` (Ember has no interior
  mutability) — read out, edit, and `replace`. This is the blessed answer for graph- and pool-shaped
  data (entity tables, retained UI nodes, object pools) that [the manifesto](../MANIFESTO.md)
  promises in place of escalating a borrow checker.

**Also in `std/` (opt-in, application support).** Beyond the core collections above, the standard
library ships modules a real 2026 program reaches for, each ordinary Ember pulled in with `import`:
**`std/json`** (parse/emit), **`std/markdown`** and **`std/highlight`** (Markdown rendering and
syntax highlighting), **`std/layout`** (a flexbox solver), and — built under `make net` —
**`std/http`** and **`std/sse`** (an HTTP client and server-sent-event streaming). The graphics and
UI stack (`std/draw`, `std/ui`, `std/flare`) has its own section, [Graphics & UI](#graphics--ui--flare).

```ember
import "std/map" as mp

fn main() -> int {
    var counts = mp.Map<string, int> { buckets: [], count: 0 }
    for w in "a b a c b a".split(" ") {
        match counts.get(w) {
            case Some(n) { counts.set(w, n + 1) }
            case None    { counts.set(w, 1) }
        }
    }
    return counts.size()      // 3 distinct words
}
```

```ember
import "std/slotmap" as sm

fn main() -> int {
    var arena = sm.SlotMap<int> { items: [], gen: [], free: [], count: 0 }
    let h = arena.insert(42)
    arena.remove(h)                 // bumps the slot's generation
    match arena.get(h) {            // the stale handle no longer resolves
        case Some(v) { return v }   // not taken — no dangling read
        case None    { return 0 }   // taken: a removed handle is a safe None
    }
}
```

```ember
import "std/string" as str

fn main() -> int {
    let name = str.trim(read_line())
    println("Hello, " + str.to_upper(name) + "!")
    return 0
}
```

## Control flow — [runs: `if`/`else`, `loop`/`break`/`continue`]

`if`/`else` (and `else if` chains) execute today. The condition **must be a `bool`** — there is
no truthiness, so `if 1 { }` is a compile error.

```ember
fn classify(n: int) -> int {
    if n < 0 {
        return -1
    } else if n == 0 {
        return 0
    } else {
        return 1
    }
}
```

`loop { }` is the unconditional loop; exit it with `break`, restart the next iteration with
`continue`. Both are only valid inside a loop (a compile error otherwise).

```ember
fn sum_to(n: int) -> int {
    var i = 0
    var total = 0
    loop {
        if i >= n { break }
        total = total + i
        i = i + 1
    }
    return total
}
```

Bindings are **block-scoped**: a `let`/`var` declared inside any block (`if`/`else`/`loop`/bare
`{ }`) is visible only to the end of that block, and a binding may **shadow** one from an
enclosing scope.

## Arrays & iteration — [runs]

An array `[T]` is a homogeneous, growable sequence. Build one with a literal, read elements by
index (bounds-checked — out of range is a runtime error), ask its size with `len`, and walk it
with `for … in`:

```ember
fn main() -> int {
    let xs = [10, 20, 30]
    var sum = 0
    for x in xs {
        if x == 20 { continue }
        sum = sum + x          // 10 + 30 = 40
    }
    return sum + len(xs)       // 40 + 3 = 43
}
```

Elements must all have the same type; an empty `[]` takes its element type from the context
(`let a: [int] = []`). `for x in a` binds each element in turn; `break` and `continue` work as
in `loop`.

`for` also iterates an **integer range** `lo..hi` — exclusive of `hi`, so `for i in 0..n` runs
`i = 0, 1, …, n-1` (and an empty or reversed range like `5..5` or `9..3` runs zero times):

```ember
var sum = 0
for i in 0..10 { sum = sum + i }      // 0+1+…+9 = 45
```

When you need both the index and the element of an array, `for (i, x) in array` binds them
together (the canonical form — clearer and faster than `for i in 0..array.len() { let x = array[i] … }`):

```ember
for (i, name) in names { println("{i}: {name}") }
```

There is exactly one range operator (`..`, exclusive) by design — an inclusive `..=` would just be
a second way to write `lo..hi+1`. So: `for x in a` (element), `for i in a..b` (a counter), and
`for (i, x) in a` (both) each cover a distinct need with no overlap.

Both forms are the idiomatic way to loop and are **2–3× faster than the equivalent hand-written
`loop { if i == n { break } … i = i + 1 }`**: each compiles to a single fused step instruction
(increment + bound check, and for arrays the element fetch and a length cached once) rather than
the dozen-odd opcodes a manual counter costs per iteration. A range is only valid as a `for`
iterator — `let r = 0..5` is a compile error.

**Arrays are mutable, uniquely-owned values — a move type, like a struct.** Binding or passing
one **moves** it (a plain parameter borrows; `mut` borrows mutably); two bindings never name the
same array, so there is no aliased mutation. Through a `var`/`mut` place an array mutates and
grows in place:

```ember
fn main() -> int {
    var a: [int] = []
    a.append(1)            // grow (amortized O(1))
    a.append(2)
    a.append(3)
    a[0] = 10              // element assignment
    let last = a.remove_last()   // 3, removed and handed back; a is [10, 2]
    return a[0] + a.len() + last // 10 + 2 + 3 = 15
}
```

The intrinsic methods are **`a.append(x)`** (grow by one), **`a.remove_last()`** (remove and
return the last element — a runtime error if empty), **`a.remove_at(i)`** (remove and return the
element at index `i`, shifting the later elements down — O(n), a runtime error if `i` is out of
range), **`a.len()`** (size; the free `len(a)` also works), and **`a.clone()`** (a deep copy — see
below). `append`/`remove_last`/`remove_at` require a mutable place; `len`, `clone`, and indexing do
not. (Mutating methods through an *index* receiver — `arr[i].xs.remove_at(j)` — are not yet
supported for the value-returning ones; bind the inner array to a variable first — OFI-072.) An array
is freed at scope exit, recursively releasing its elements (a non-GC, deterministic reclamation —
see [Memory model](#memory-model--runs-structsarrays-freed-stringsenums-reference-counted)).

**Storage — packed scalar buffers.** An array of a scalar element (`[u8]`, `[i32]`, `[u64]`,
`[f32]`, `[f64]`, `[bool]`, …) is stored in a **packed native buffer** at the element's natural
width — a `[u8]` of N elements is N bytes, an `[i32]` is N×4 — not N×16. Indexing boxes the
element back to a value and assignment/append truncates or rounds it to the width (the element
type drives a literal's inference, so `bytes.append(40)` and `xs[0] = 200` need no suffix). Arrays
of other heap objects (`[string]`, an enum, a nested array) keep the uniform value layout.

**Slices — borrowed views, zero-copy.** `arr[lo..hi]` is a **`Slice<T>`**: a read-only view over
`arr`'s elements from `lo` (inclusive) to `hi` (exclusive), with no copy. You read it like an array
(`s[i]`, `s.len()`, `for x in s`), slice it again (`s[1..3]`), and pass it to any function that takes
a `Slice<T>`:

```ember
fn sum(xs: Slice<int>) -> int {
    var t = 0
    for x in xs { t = t + x }
    return t
}

fn main() -> int {
    let data = [10, 20, 30, 40, 50]
    let win = data[1..4]                 // a view of [20, 30, 40] — no allocation
    return sum(win) + sum(data[0..data.len()])   // 90 + 150
}
```

A slice **borrows** its source, so the compiler keeps it sound without lifetimes: while a slice is
alive, its source array is **frozen** (you can't `append`, reassign, or move it — that would dangle
the view), and a slice **cannot escape** — it may be a parameter or a local, but never a return
type, a struct field, or an array element. When you need to *keep* a sub-array, use the copying
companion **`arr.slice(lo, hi)`**, which returns a fresh **owned `[T]`** you can return or store.
(Returnable views and mutable/write-through slices are deliberately deferred — they need full
lifetime inference; see the architecture notes.)

**Deep copy — `.clone()`.** Arrays and structs are **uniquely owned** (§memory model), so the
compiler will not let you silently make a second owner of one. Reading an element of a struct array
out by move — `backup.append(convos[i])` — is therefore a *compile error* ("cannot move a struct out
of an array element"): a shallow copy would alias the element's heap fields and double-free them.
When you genuinely want an independent copy, ask for one explicitly with **`.clone()`**:

```ember
backup.append(convos[i].clone())   // an independent deep copy — legal, explicit
let snapshot = grid.clone()        // a whole [[int]], copied; grows independently of grid
let m2 = scores.clone()            // a Map<K,V> — deep-cloned, fully independent
```

`x.clone()` returns an independent deep copy of the receiver: array elements and struct fields are
cloned **recursively**, so mutating the clone (or the original) never affects the other. It is
available on **arrays** and on **structs** — including generic structs such as `Map<K,V>` and
`Set<K>`. The cost is **visible at the call site** (Ember never deep-copies implicitly — see the
manifesto on explicit cost). A user-defined `clone` method on a struct takes precedence over the
built-in. It is not offered on scalars (assignment already copies them), on immutable shared values
(strings, enums — assignment already gives you a usable handle), or on a slice (use `arr.slice(0,
arr.len())` to copy a view into an owned array). *(Native-backend note: value-struct `.clone()` is
currently VM-only; array `.clone()` works on both backends — see [OFI.md](OFI.md) OFI-082.)*

**Storage — inline struct arrays (value types).** An array of an **all-scalar struct** (every
field a scalar, total ≤ 255 bytes — e.g. `struct Pixel { r: u8  g: u8  b: u8 }`) packs its
elements **inline** in the buffer too: a `[Pixel]` of N is N×3 bytes, with no per-element heap
object (≈10× smaller than the boxed layout). Such elements are **value types** — `arr[i]` yields a
**copy**, so it can be bound out (`let p = arr[i]`) and a mutation of the copy does not affect the
array. (A boxed struct array would forbid binding the element out, since that would alias the
array's unique owner.) A struct with a **unique-owner** field (a nested struct or array) falls back
to the boxed layout; a **refcounted** field (a string, enum, or closure) keeps the element inline —
the index-copy shares it by `incref`. This and packed scalars are the first steps of native layout;
the value model is otherwise still width-erased.

**Storage — inline nested struct fields (value types).** A struct field whose type is another
**all-scalar struct** is stored **inline**: its packed bytes embed directly in the parent's buffer,
with no separate heap object (a `Line { a: Pt, b: Pt }` is one object, not three). Such a field is a
**value**: reading it whole copies it (`let p = ln.a` — the source stays valid and the copy is
independent), assigning through it writes back (`line.a.x = 5`), and constructing the parent packs
the field bytes in place. Nesting is recursive (a struct of structs of scalars packs flat). A field
that is a string, an array, a nested *non*-all-scalar struct, or a type parameter still uses the
boxed layout for now.

**Stack — multi-slot struct locals and parameters (value types).** An **all-scalar struct** —
every field a scalar **or another all-scalar struct, recursively** — held by an immutable `let`
binding, or passed as a plain (borrow) parameter to a non-generic free function, is stored
**multi-slot**: its leaf fields live directly in consecutive stack slots, with no heap object at
all (a nested `Line { a: Pt, b: Pt }` occupies four slots — `a.x, a.y, b.x, b.y`; `ln.a.x` reads
one, `ln.a` is the two-slot sub-range). Such a struct is fully a value type: `var dup = ln` copies
it, and it passes and returns by value. Field access (`p.x`) reads a slot; reading the whole value (`let q = p`,
passing it on, returning a value built from it) **copies** it, so the source stays usable — these
are value types. A call passes such an argument as its field slots in place: a multi-slot
local/parameter copies its slots (no allocation), and any other value (a fresh `P{…}`
construction, an array element) is materialised and exploded into slots. This applies to the
direct call and `spawn` paths; a `mut`/`move` parameter (which must mutate or take the caller's
value) and a generic function keep the boxed layout, and a function with such a parameter cannot
yet be used as a first-class function value (a closure dispatches boxed). `var` (mutable) struct
locals also stay boxed for now.

A non-generic free function that **returns** an all-scalar struct returns it multi-slot too: the
callee moves its field slots straight into the caller's frame, no box. Forwarding a value
(`return p`, `return a`) costs nothing, and `let q = f()` binds the returned slots directly.
**Constructing** one in a value position is also box-free: `let p = Pt{…}` builds the fields
straight into the binding, `return Pt{…}` straight into the return, and `f(Pt{…})` straight into
a multi-slot parameter — so a constructor function (and the call that consumes it) allocates
nothing. The remaining uses of a struct value (a field access on a literal, a discarded result)
box it transparently, so they behave exactly as before.

A **method** on a non-generic struct takes its explicit struct parameters and returns a struct
multi-slot too, the same way — `let q = p.translate(d)` allocates nothing for `d` or the result.
(The receiver `self` is still boxed on the way in, and a method that implements an interface
keeps the boxed convention, since bounded generic code may dispatch it through a witness.)
Generic functions/structs, and using a struct-passing/returning function as a first-class value,
keep the boxed convention for now.

## Generics — [runs: structs, enums, functions, methods, and bounds]

A struct may take **type parameters**: `struct Box<T> { value: T }`. Each *instantiation* —
`Box<int>`, `Box<string>`, `Pair<int, bool>` — is a distinct type, and a field's type
substitutes the parameter accordingly (`Box<int>.value` is `int`). Instantiations may nest
(`Box<Box<int>>`). Type arguments are written explicitly at construction
(`Box<int> { value: 42 }`).

Ember deliberately has **no turbofish** (`Box::<int>`): the clean `Name<T> { … }` form is
unambiguous on its own. The parser reads `Name<…> {` as a generic literal only when the angle
brackets enclose a well-formed type-argument list immediately followed by `{`; because no
expression can begin with `{`, a `> {` sequence can never be a comparison, so `a < b` and
`Pair<int, int> { … }` never collide. (See `docs/grammar.ebnf` note (G); OFI-002.)

```ember
struct Pair<A, B> {
    first:  A
    second: B
}

fn main() -> int {
    let p = Pair<int, int> { first: 3, second: 4 }
    return p.first + p.second   // => 7
}
```

**Enums are generic too**, which is how `Option<T>` and `Result<T, E>` are ordinary library
types rather than built-ins. They live in the **prelude** — injected into every program — so you
use `Some`/`None`/`Ok`/`Err`, the `?` operator, `recv`, and `parse_int` without declaring anything:

```ember
// Option and Result come from the prelude — no `enum` declarations needed here.
fn safe_div(a: int, b: int) -> Option<int> {
    if b == 0 { return None }
    return Some(a / b)
}

fn main() -> int {
    match safe_div(10, 2) {
        case Some(v) { return v }   // v binds as int → 5
        case None    { return 0 }
    }
    return 0
}
```

The prelude defines exactly:

```ember
enum Option<T> { Some(value: T)  None }
enum Result<T, E> { Ok(value: T)  Err(error: E) }
```

A program may still declare its own `Option`/`Result` (its definition wins; the prelude's is
skipped), but it no longer needs to. Because the prelude is always in scope, `Some`/`None`/
`Ok`/`Err` are effectively reserved — another enum visible alongside the prelude can't reuse them.
(Two enums in *different* non-prelude modules may share a variant name, though — see "variant
visibility" below; only enums visible together must keep their variant names distinct.)

The prelude is its own **always-in-scope module**: its types resolve unqualified from *every*
module, the entry file and any `import`ed one alike. So a library module can declare
`fn first(…) -> Option<int>` and return `Some(x)`/`None` without importing or redeclaring
anything — exactly as the entry module does.

**Type arguments are inferred** at construction from two sources: the **argument** (a field
declared `T` fixes `T` to the argument's type, so `Some(5)` is `Option<int>`) and the **expected
type** from a `let` annotation or a function's return type (so `None` and `Result`'s second
parameter resolve). When neither pins a parameter — a bare `None` with no annotation — Ember asks
for an annotation rather than guessing.

**Functions and methods are generic too.** A function declares its own parameters
(`fn id<T>(x: T) -> T`); a method on a generic struct uses the struct's (and may name `Self`).
Type arguments are **inferred** at the call — from the argument types and the expected return
type — so calls read naturally with no turbofish:

```ember
fn identity<T>(x: T) -> T { return x }

struct Box<T> {
    value: T
    fn get(self) -> T { return self.value }              // T comes from the receiver
    fn replaced(self, n: T) -> Box<T> { return Box<T> { value: n } }
}

fn main() -> int {
    let s = identity("hi")                  // T = string (from the argument)
    let b = Box<int> { value: 3 }
    return b.replaced(7).get()              // => 7   (b.replaced : Box<int>, .get : int)
}
```

Inference unifies structurally: `unwrap<T>(b: Box<T>) -> T` recovers `T` from a `Box<int>`
argument, and `none_of<T>() -> Option<T>` recovers it from an expected `Option<int>`. When a
parameter is pinned by neither argument nor expected type, Ember asks for an annotation. Within a
generic body `T` is **opaque** — you may pass, store, and return it, but not do arithmetic on it
or call methods (that needs a bound).

Because every value is uniformly represented, generics are **erased** — `Box<int>` and
`Box<string>` share one compiled layout and a generic function/method is compiled **once**, so
there is no per-instantiation code. This is the manifesto's erased path (§5).

**Bounds** let a generic call the interface methods of its type parameter:

```ember
interface Ord { fn compare(self, other: Self) -> int }

struct Version implements Ord {
    n: int
    fn compare(self, other: Version) -> int { return self.n - other.n }
}

fn max<T: Ord>(move a: T, move b: T) -> T {   // T must implement Ord; returns one arg
    if a.compare(b) >= 0 { return a }         // dispatched through a witness
    return b
}
```

Since the body is compiled once with `T` unknown, `a.compare(b)` cannot resolve statically.
Instead the caller passes a **witness** — the dictionary of the concrete type's methods for the
bound interface — as a hidden argument, and the call dispatches through it (`OP_CALL_INDIRECT`).
The type argument must be a struct that `implements` the bound (so `max(1, 2)` is rejected — `int`
implements no interface yet). Without a bound, `T` is opaque and has no methods.

**Ownership holds inside generic bodies (MANIFESTO §5f).** A type parameter `T` is a **move type
by default**, so a generic body is ownership-checked just like concrete code — a `T` value can't
be silently aliased or returned from a borrow (that previously double-freed a struct argument at
run time). That's why `max` above returns *one of its arguments*, so it takes them `move`. For
copyable types there is the **`Copy` bound**:

```ember
fn id<T: Copy>(x: T) -> T {       // T: Copy ⇒ aliased and returned by copy, no `move`
    return x
}
```

`Copy` composes with an interface bound (`T: Ord + Copy`). It means *every type except a struct or
array* — scalars copy bitwise; strings, enums, and closures are immutable + reference-counted, so
copying one is a cheap `incref`. Binding a struct or array to a `Copy` parameter is a compile
error (`type argument is not Copy`). *Current limits:* one **interface** bound per generic
**function** (plus `Copy`), and inference is call-site only (no turbofish). Bounds on generic
**structs** do run — `struct Map<K: Hash + Eq, V>` carries its key witnesses per instance — but
bounds on generic **enums** and on standalone **methods** are not yet supported.

## Types — [parses, except `int`/`bool` which run]

- **Named:** `int`, `bool`, `Point`, `Self`
- **Generic application:** `Result<Config, string>`, `Option<T>`
- **Array:** `[T]`, `[string]`

### Numeric types

Ember has an explicit-width numeric family — `i8 i16 i32 i64`, `u8 u16 u32 u64`, `f32 f64` —
with two ergonomic aliases for the common case: **`int` = `i64`** and **`float` = `f64`**. Use
`int`/`float` by default; reach for a specific width when range matters. `bool` is its own type
and is never numeric.

**The whole family runs** — every integer width and both floats. A width is **semantic** today:
it constrains range and type, but every value is the same size at runtime (the value model is
width-erased), so packed layout is a later concern. Because the bits are erased, the width is
carried on the *operations* — arithmetic, ordering comparisons, and display each take the
operand's width — so a `u64` above 2⁶³ adds, compares, and prints as unsigned, and an `f32` rounds
to 32-bit after each step. (One current limit of the erased model: a `u64` *literal* can be
written only up to 2⁶³−1; larger `u64` values are reached by arithmetic or conversion.)

A **literal** takes its width from context (an annotation, a parameter, or the other operand:
`let x: u8 = 200`, `f(7)` into a `u8` parameter, `x + 1` where `x` is `u8`) or from a **suffix**
(`200u8`, `42i32`); out-of-range is a compile error. There is **no implicit coercion** between
widths or between int and float — convert **explicitly**: an integer width with a **type-name
call** (`u8(x)`, `i32(x)`, `i64(x)` — range-checked, a trap if it doesn't fit; `u64(x)`
reinterprets the bits), a float width with `f32(x)`/`f64(x)`, and int↔float with
**`to_float`**/**`to_int`** (`to_int` truncates toward zero). Mixing widths (`an_i32 + an_i64`) or
int and float (`1 + 2.0`) is a compile error. **Arithmetic overflow traps at the operand's
width** — `200u8 + 100u8` is a runtime error, just as `int` overflow is at 64 bits — rather than
wrapping; `%` requires integer operands. Float arithmetic follows IEEE-754 (division by zero
yields infinity, not a trap).

**Wrapping arithmetic, when you actually want it.** Trapping is the default because silent overflow
is a footgun; but hashes, PRNGs, and checksums *depend* on modular (2^width) arithmetic. So the
wrapping direction is available **explicitly**, as three builtins that wrap instead of trapping —
mirroring how `move` makes the dangerous ownership move explicit, so a model never reaches for it by
accident:

```ember
fn fnv1a(s: string) -> u32 {
    var h: u32 = 2166136261u32
    let bytes = s.chars()
    var i = 0
    loop {
        if i == bytes.len() { break }
        h = wrapping_mul(h ^ u32(char_code(bytes[i])), 16777619u32)   // wraps at 2^32
        i = i + 1
    }
    return h
}
```

`wrapping_add(a, b)`, `wrapping_sub(a, b)`, and `wrapping_mul(a, b)` take two integers of the same
width and return that width, computing modulo 2^width (two's-complement for the signed types) with
no overflow trap. There is no wrapping `/` or `%` (overflow there isn't a real use case).

Ownership qualifiers (`mut`/`move`) are **not** part of a type — they are written before a
parameter binding; see [Ownership](#ownership--runs-mutation--moveborrow-safety-lifetime-inference-designed).

---

## Composite types — [structs, methods, interface conformance, and enums run]

A `struct` declares a named aggregate of typed fields, with optional **methods**. Construction,
field reads, and methods all execute today; structs pass to and from functions like any value,
and a field's type may be `int`, `bool`, or another struct. A field is **mutated** through a mutable
place — a `var` binding or a `mut`/`move` parameter (`p.x = v`, including nested paths `p.a.b = v`);
see [Ownership](#ownership--runs-mutation--moveborrow-safety-lifetime-inference-designed).

### Interfaces and `implements` conformance

An `interface` lists required method signatures. A struct declares it satisfies one with
`implements`, and the compiler **checks the conformance** — the struct must provide each
required method with a matching signature, where the interface's `Self` resolves to the
implementing struct. Conformance is **nominal** (declared, not inferred) and **checked**.

An interface is used two ways, both running today:

- **As a generic bound** (`fn max<T: Ord>(…)`) — dispatch is static, through a *witness* (the
  concrete type's method table). A type parameter may have **several bounds** (`<K: Hash + Eq>`)
  and bounds work on **generic structs** too (`struct Map<K: Hash + Eq, V>`); a bounded
  struct stores its type arguments' witnesses per instance, so a method can call `key.hash()` on
  an erased `K`. Built-in scalar/string types satisfy `Hash`/`Eq` automatically; a user struct
  does so with `implements Hash, Eq`.
- **As a value type** (`let s: Shape = circle`, a `Shape` parameter/return/field, a `[Shape]`
  array) — **dynamic dispatch**. A struct upcasts to the interface implicitly wherever the
  interface type is expected, producing an interface value: a boxed pair of `{receiver, vtable}`
  (Go's `(data, itable)` / Rust's `dyn`). A method call on it resolves through the vtable at run
  time, so a single `[Shape]` can hold a mix of concrete shapes — polymorphism without
  inheritance. The interface value owns its receiver and is freed (dropping the receiver) at
  scope exit, like any other value.

An interface is usable as a **value type only if it is *object-safe***: no method may mention
`Self` outside the receiver position (no `other: Self` parameter, no `-> Self` return), because
once the concrete type is erased behind the interface there is no second value of "the same type"
to supply. Such an interface (e.g. `Ord` with `compare(self, other: Self)`) is still fully usable
as a **generic bound**, where the concrete type is known. The compiler reports a clear error if
you try to use a non-object-safe interface as a value type.

```ember
interface Ord {
    fn compare(self, other: Self) -> int
}

struct Version implements Ord {
    number: int
    fn compare(self, other: Version) -> int {   // Self == Version here
        return self.number - other.number
    }
}

fn main() -> int {
    let a = Version { number: 5 }
    return a.compare(Version { number: 4 })      // => 1
}
```

`Ord` above is *not* object-safe (its `compare` takes `other: Self`), so it works as a bound but
not as a value type. An object-safe interface — one whose methods only ever use `Self` as the
receiver — can be used dynamically:

```ember
interface Shape {
    fn area(self) -> float
}

struct Circle implements Shape {
    radius: float
    fn area(self) -> float { return 3.14159 * self.radius * self.radius }
}

struct Rect implements Shape {
    w: float
    h: float
    fn area(self) -> float { return self.w * self.h }
}

fn main() {
    // One element type, several concrete types — dispatched at run time.
    let shapes: [Shape] = [Circle { radius: 2.0 }, Rect { w: 3.0, h: 4.0 }]
    for s in shapes {
        println("area {s.area()}")               // 12.566… then 12
    }
}
```

A struct that names an interface in `implements` but lacks a required method, gives a method a
mismatched signature, or names an unknown interface, is a compile error.

A method takes `self` (the receiver) as its first parameter, written explicitly. Inside, it
reads the receiver's fields (`self.x`) and may call the receiver's other methods (`self.m()`).
Calls are checked for arity and argument types, and dispatch is static (the receiver's type is
known at compile time).

```ember
struct Counter {
    value: int

    fn bump(self, by: int) -> int {
        return self.value + by
    }
}

struct Line {
    start: Counter
    end:   Counter
}

fn main() -> int {
    let c = Counter { value: 10 }
    return c.bump(15)        // => 25
}
```

Construction requires every field set exactly once, with matching types; reading a missing
field, calling a missing method, or a field/method on a non-struct, is a compile error.

Enums are covered in their own section below. Methods may lean on the standard library — `sqrt`
and friends are native primitives now, so this **runs**:

```ember
struct Point {
    x: float
    y: float

    fn distance(self, other: Point) -> float {
        let dx = self.x - other.x
        return sqrt(dx * dx)        // sqrt is a native primitive
    }
}
```

---

## Enums and pattern matching — [runs]

An `enum` is a sum type: a value is exactly one of its variants, each of which may carry typed
fields. Variants are constructed by name — bare for zero-field variants, call-style for
data-carrying ones. A variant may also be **named through its enum**, `Color.Blue(5)` / `Option.None`,
which is exactly equivalent to the bare form (the qualifier is checked, then dropped) — handy when you
want the enum spelled out, and the form an LLM tends to reach for.

**Variant visibility.** A bare variant name (`Blue`, `Some`) resolves among the enums *visible from
where it is written* — the current module plus the always-in-scope prelude. So variant names must be
distinct only among **enums that are visible together**: within one module, and against the prelude
(`Some`/`None`/`Ok`/`Err`). Two enums in *different* non-prelude modules may both define a `Str` (or
`Node`, `Value`, …) without clashing — a bare reference in either module sees only its own, never the
other's. A `match` resolves each `case` within the *scrutinee's* enum regardless. Codegen builds and
dispatches each variant by the enum id + tag the checker resolved — never a by-name lookup — so the
no-longer-global names stay sound on both backends. An **imported** enum's data-carrying variant is
constructed **qualified**: `json.Obj([...])`, `mp.Some(x)` — resolved in the aliased module.

```ember
enum Shape {
    Circle(r: int)
    Rect(w: int, h: int)
    Origin                  // zero-field variant: no parens
}

fn area(s: Shape) -> int {
    match s {
        case Circle(r)  { return r * r * 3 }
        case Rect(w, h) { return w * h }     // w, h bind the variant's fields
        case Origin     { return 0 }
    }
    return -1
}

fn main() -> int {
    return area(Rect(3, 4))   // => 12
}
```

`match` is **exhaustive** (every variant must be handled, or it's a compile error), has **no
fallthrough** (first match wins), and binds each variant's fields as case-scoped locals. A
duplicate case for a variant, or matching a non-enum value, is a compile error.

A **`case _`** arm is a catch-all: it handles every variant not named by an earlier arm, so a
match stays exhaustive without listing them all (a case after it is a duplicate — the catch-all
goes last). `_` *inside* a variant pattern (`case Some(_)`) is an **ignored binding** — it drops
the field and, like any `_`, cannot be read — not a catch-all wildcard.

```ember
match color {
    case Red   { return 1 }
    case Green { return 2 }
    case _     { return 0 }   // everything else
}
```

`match`/`for`/`if` headers disable struct-literal syntax so the trailing `{` reads as a block;
wrap a genuine struct literal in parentheses there if ever needed.

---

## Errors & optionals — [runs]

No exceptions and no `null`. Failure is a value, carried by two ordinary generic enums (see
[Generics](#generics--runs-structs-enums-functions-methods-and-bounds)) — they are library types, not built-ins:

- `Result<T, E>` — `Ok(v)` or `Err(e)`
- `Option<T>` — `Some(v)` or `None`
- `?` — unwrap an `Ok`/`Some` payload, or **return the `Err`/`None` to the caller early**,
  replacing `if err != null { return err }` chains

```ember
enum Result<T, E> { Ok(value: T)  Err(error: E) }

fn checked(n: int) -> Result<int, string> {
    if n < 0 { return Err("negative") }
    return Ok(n)
}

fn sum(a: int, b: int) -> Result<int, string> {
    return Ok(checked(a)? + checked(b)?)   // any Err short-circuits the whole function
}
```

`expr?` requires the enclosing function to return the same kind — a `Result` with the *same
error type* (for `Result?`), or an `Option` (for `Option?`) — so the propagated failure always
type-checks. The success payload is the value of the expression. Multiple `?` may appear in one
expression; the first failure returns immediately and the rest is abandoned.

---

## Concurrency — [runs]

Structured concurrency. Tasks are scoped to a `nursery` block and cannot outlive it: the block
does not exit until every `spawn`ed task has finished. No async/await colouring — any `fn` is
spawnable. Tasks communicate over typed **channels**: a `send` to a full channel or a `recv`
from an empty one blocks the task until the channel is ready.

The concurrency model is **independent of how many cores it runs on** — this is the payoff of
the ownership model. The default runtime is a cooperative scheduler on one OS thread (green
threads — the manifesto's "one language-owned runtime"); a `send`/`recv` that cannot proceed
yields and the scheduler resumes it. The **parallel runtime** (the compiler built with
`EMBER_PARALLEL=1`) runs the *same* programs across all cores: each `spawn`ed task gets a real
OS thread, channels block on a condition variable rather than yielding, and the `nursery` join
is a thread barrier. No source changes — `nursery`/`spawn`/`Channel<T>` mean the same thing,
the answer is identical, only wall-clock time differs. This is sound *because* ownership already
makes user data race-free by construction: scalars are copied, structs/arrays are unique-owner
move types (never aliased across tasks), and strings/enums/closures are immutable and
refcounted — so the only cross-thread mutable state in the whole heap is each object's refcount,
which the parallel runtime makes atomic. A **channel** is the one intentional exception — a
shared, mutable rendezvous point — so its buffer is lock-protected (parallel) and the handle
itself is **refcounted** like a string: the creating scope and every task it is `spawn`ed into
each hold a counted reference, and the channel (its buffer and OS primitives) is reclaimed when
the last owner drops it, not deferred to program exit. All runtimes also report a genuine
**deadlock** (every task in a nursery blocked on a channel that can never progress) as the same
runtime error rather than hanging. For allocation, each worker keeps a private, lock-free pool
and object list, so tasks that allocate heavily scale instead of contending on one heap lock; a
value handed to another task through a channel is freed correctly on the receiving thread.

A `recv` blocks until a value arrives (or the channel closes); **`try_recv`** polls *without*
blocking — `Some(v)` if a value is queued right now, `None` otherwise — the primitive an event
loop needs to stay responsive. On the parallel runtime a `spawn`ed task starts running the moment
it is spawned, concurrently with the rest of the nursery body, so a loop in the body can
`try_recv` a background task's results as they arrive and the closing brace simply joins it. (The
serial runtime is fork-join — the body runs to the nursery's end *before* the cooperative
scheduler runs the spawned tasks — so a poll loop that depends on concurrent spawn progress is a
parallel-runtime idiom; blocking `send`/`recv` programs give the identical answer on both.)

```ember
fn producer(ch: Channel<int>) {             // a unit function — runs for effect
    send(ch, 10)
    send(ch, 20)
    send(ch, 30)            // buffer (2) is full here → this task yields
    close(ch)              // no more values: a drained recv now returns None
}
fn consumer(ch: Channel<int>, out: Channel<int>) {
    var sum = 0
    loop {
        match recv(ch) {
            case Some(v) { sum = sum + v }   // a value arrived
            case None    { break }           // channel closed and drained
        }
    }
    send(out, sum)
}

fn main() -> int {
    let ch:  Channel<int> = channel(2)       // buffered, capacity 2
    let out: Channel<int> = channel(1)
    nursery {
        spawn producer(ch)
        spawn consumer(ch, out)
    }                                        // both finished here
    match recv(out) {
        case Some(v) { return v }            // => 60
        case None    { return 0 }
    }
    return 0
}
```

- **`nursery { … }`** — a structured task group; the block joins all its tasks before exiting.
- **`spawn f(args)`** — launches a call to a named function as a task in the enclosing nursery
  (a compile error outside one). Arguments follow the ownership rules: a `move` argument transfers
  into the task; a borrow is safe because the nursery guarantees the task finishes within the
  data's scope.
- **`Channel<T>` / `channel(N)`** — a buffered channel of capacity `N`. Its element type is
  inferred from the binding annotation (`let c: Channel<int> = channel(N)`). Channels are
  *shareable* (the same channel passes to several tasks) and not move types.
- **`send(ch, v)`** moves `v` into the channel (blocks when full). **`recv(ch)`** takes the next
  value, returning **`Option<T>`** — `Some(v)` while values are available, and `None` once the
  channel is **closed and drained**. It blocks only on an *open* empty channel; if every task in a
  nursery is then blocked, that's a **deadlock** runtime error.
- **`close(ch)`** marks a channel closed (idempotent, no value). Queued values still drain; after
  that, `recv` returns `None` instead of blocking — this is how a consumer loop terminates. `recv`
  returns the prelude's `Option<T>`, so a drained channel hands back `None` with no enum to declare.
  **`send` on a closed channel is a runtime error** ("send
  on a closed channel") — a programming mistake, like an out-of-bounds index or an overflow (OFI-086),
  not a recoverable value; close a channel only once every `send` is done.

**Runtimes & status.** Three schedulers run the *same* source: the default **cooperative N:1**
scheduler (one OS thread); a **1:1 thread-per-spawn** runtime (`make parallel`, `-DEMBER_PARALLEL`),
which is also what a native `emberc -o` binary uses; and an **M:N green-thread** scheduler (`make mn`,
`-DEMBER_MN`) — a worker pool multiplexing many lightweight fibers that *park* on channels, with
structured nursery join, cancellation-on-failure (a failing task tears its group down at yield
seams), and global deadlock detection. The M:N scheduler is **built but VM-only and opt-in**, gated
behind its flag pending a wider soak (and segmented fiber stacks for the 100k-fiber tier) before it
becomes the default. **Still deferred:** `select`/timeouts, and main↔child channel communication
*during* a nursery (main drives the join, so channels are for child↔child).

---

## Modules — [runs]

A source file is a module. `import "path" as name` brings another module into scope under an
explicit alias, and its members are used **qualified** through that alias — so a name's origin is
always visible (no implicit flat merging, no collisions). Paths resolve relative to the importing
file (with `.em` appended); all transitively-imported modules are loaded, deduped, and compiled as
one program (mutual imports are fine).

```ember
// modlib/mathx.em
fn _step(n: int) -> int { return n + 1 }      // private (leading _)
fn square(n: int) -> int { return n * n }     // public
fn cube(n: int) -> int { return square(n) * _step(n - 1) }
```
```ember
// main.em
import "modlib/mathx" as mathx
fn main() -> int {
    return mathx.square(5) + mathx.cube(2)     // 33
}
```

**Visibility — the leading-underscore convention** (FROG-style): a top-level declaration whose
name starts with `_` is **private to its module**; everything else is exported. It is *enforced* —
calling `mathx._step(…)` from another module is a compile error — but only applies to top-level
declaration names (so `_` stays free for future use in patterns / ignored bindings). Default is
public; opt into privacy with `_`.

Enforcement covers top-level **free functions, types, and constants** — the things you reach
through a module qualifier (`mod._name`). It does **not** cover a struct's **methods**: a method
whose name starts with `_` (`fn _helper(self)`) is a *convention/hint* — "internal, don't lean on
this" — but is **not** enforced, so `value._helper()` is callable from another module once you hold
a value of that type. The reasoning: a free function is reached only by module-qualified name, which
visibility can gate; a method belongs to its *type*, which travels wherever the value does, so there
is no qualifier to gate. (Two standard-library modules rely on this — `std/flare` builds on `std/ui`,
reaching some of its `_`-prefixed methods across the module boundary.) This asymmetry is deliberate but acknowledged as a
rough edge; a future module-system pass is expected to replace the `_` convention with explicit
`pub`/visibility that is uniform for both. See [OFI.md](OFI.md) OFI-081.

Imported **types** are named qualified too — `mod.Point`, `mod.Shape<T>` — in any annotation
(parameter, `let`, return, field, type argument), and **constructed qualified** with a struct
literal: `geom.Point { x: 1, y: 2 }`, including the generic form `box.Box<int> { value: 42 }`. A
module may of course also export a constructor *function* (`geom.make(…)`); either way, field
access and methods work normally, since a value's type is module-independent once resolved.

```ember
// geom.em
struct Point { x: int  y: int }
fn make(x: int, y: int) -> Point { return Point { x: x, y: y } }
fn sum(p: Point) -> int { return p.x + p.y }
```
```ember
// main.em
import "geom" as geom
fn main() -> int {
    let p = geom.Point { x: 3, y: 4 }   // qualified construction literal
    return geom.sum(p)                   // 7
}
```

**Runs today:** module loading; module-qualified **function** calls, **types**, and **construction
literals** (`geom.Point { … }`, generic `box.Box<int> { … }`); the always-in-scope **prelude**, so
bare `Some`/`None`/`Ok`/`Err` and `match` work in any module; enum-qualified variant construction
for an in-scope enum (`Color.Blue(5)`, `Option.None`); a `std/`-rooted **standard library**
(`import "std/string"`, `import "std/map"`, `import "std/list"`); **generic functions called
qualified** (`list.map(xs, f)` infers its type arguments like a direct call); the `_`-privacy rule
(on functions *and* types). **Deferred:** *cross-module* qualified variants of an imported enum
(`geom.Color.Red` — two qualifiers); separate compilation.

---

## Foreign functions — C FFI [runs: scalars + structs by value + pointers/buffers/handles]

An **`extern "c"` block** declares foreign (C) functions by their Ember-side signature; you then
call them like any function (MANIFESTO §5h):

```ember
extern "c" {
    fn sin(x: f64) -> f64
    fn atan2(y: f64, x: f64) -> f64
}

fn main() -> int {
    return to_int(atan2(1.0, 1.0) * 1000.0)   // pi/4 → 785
}
```

The `extern` declaration **is the trust boundary** — there is no raw `unsafe`; the signature you
write is what Ember type-checks against. The first slice covers **scalar** arguments and returns
against the C math library (`libm`, part of the standard C runtime — no new dependency): the
exposed functions are `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `exp`, `log`, `log2`,
`log10`, `sinh`, `cosh`, `tanh`, `cbrt`, `trunc`, `hypot`, `fmod`. (`sqrt`, `pow`, `abs`, `floor`,
`ceil`, `round` are already built-in, so they need no `extern`.) The declared signature must match
the C function, or it is a compile error.

**Structs by value** cross the boundary too — that is the C ABI. An all-scalar struct argument is
flattened to its scalar leaves on the Ember side, and the C wrapper reassembles a *concrete C
struct* and passes (or returns) it by value, so the system C compiler generates the platform's
exact aggregate calling convention — no hand-rolled marshalling, no `libffi`. The boundary is
defined by the **leaf-scalar sequence**, so a `struct Vec2 { x: f64  y: f64 }` matches a C
`struct { double x, y; }`:

```ember
struct Vec2 { x: f64  y: f64 }
extern "c" {
    fn cvec2_len(v: Vec2) -> f64           // struct in, scalar out
    fn cvec2_add(a: Vec2, b: Vec2) -> Vec2 // struct in AND struct out
}
```

(The registry ships a small demonstration C vector library — `cvec2_len`/`cvec2_dot`/`cvec2_add`/
`cvec2_scale`.)

**Pointers, buffers, and opaque handles** cross the boundary too — enough to bind real C. Three
flavours, all **borrowed for the duration of the call** (Ember keeps ownership and frees nothing C
owns):

| Ember type        | C parameter   | Notes                                                             |
|-------------------|---------------|-------------------------------------------------------------------|
| `string`          | `const char*` | the string's NUL-terminated bytes; read-only                      |
| `[u8]` (any packed scalar array) | a buffer | the array's contiguous native storage, passed as a pointer    |
| `mut [u8]`        | a writable buffer | C may write the elements in place                             |
| `Ptr`             | an opaque handle (`FILE*`, `void*`, …) | round-trips to/from C; never dereferenced in Ember |

A `Ptr` is opaque: you receive one from C (e.g. `fopen`), pass it back to C (`fread`, `fclose`),
and never inspect it from Ember — its lifetime is managed explicitly in C. A `Ptr` is a **linear**
handle (OFI-049): it must be consumed **exactly once** — used *at most* once (move-only) and *at
least* once (must-close).

- **Move-only (used at most once).** An extern parameter declared `move` (only a `Ptr` may be)
  **consumes** the handle, so a closing call like `fn fclose(move f: Ptr)` takes ownership and any
  *reuse* afterward — `fclose(f); fclose(f)`, or even reading `f` again — is a **compile error**
  ("use of `f` after it was moved"), turning a C double-close into a caught bug. Pass a `Ptr`
  *without* `move` (the default, `fread`/`fwrite`) to **borrow** it and keep using it.
- **Must-close (used at least once).** An *owned* `Ptr` that reaches the end of its scope without
  being closed (or returned to transfer ownership) is a **compile error** — *"this `Ptr` is opened
  but not closed on this path"* — on **every** control-flow path (an `if` that closes on one branch
  must close on both; an early `return` or `?` must close first). This catches the leak that a C
  program would commit silently. A handle has **no destructor** (Ember can't know whether to call
  `fclose`/`free`/`sqlite3_close`), so it can't auto-close — you must close it explicitly. The
  null-handle case stays simple because `fclose(NULL)` is a guarded no-op: open, use under a
  null-check, then **one unconditional close**. Because a `Ptr` has no destructor and can't be
  auto-dropped, it also **cannot be stored** in a struct/array/enum/channel or used as a generic type
  argument (`Option<Ptr>`, `Map<_,Ptr>`, `[Ptr]` are all rejected) — keep it in a local and close it,
  or return it. A *borrowed* `Ptr` cannot be closed (you don't own it) — take it `move` to gain
  ownership.

A buffer must be a **packed scalar array** (`[u8]`, `[i32]`, `[f64]`, …); a `[string]`/`[struct]` is
boxed, not a C buffer, and is rejected. The registry ships a slice of libc to demonstrate all three:

```ember
extern "c" {
    fn strlen(s: string) -> i64
    fn fopen(path: string, mode: string) -> Ptr
    fn fwrite(buf: [u8], n: i64, f: Ptr) -> i64
    fn fread(mut buf: [u8], n: i64, f: Ptr) -> i64   // C writes into the buffer
    fn fclose(move f: Ptr) -> i64
}
```

Passing a heap value (a `string` literal, a freshly-built array) borrows it for the call and the
caller reclaims it afterward, so `strlen("hello")` leaks nothing. (A C function that *returns*
owned memory — a `char*` Ember would have to copy or free — is a deliberate future widening; see
OFI-043. Arbitrary dynamic linking likewise remains future work.) See `examples/16_ffi.em`.

> **Replay note:** `--emit=replay` captures a C call's scalar *result* but not the bytes a C
> function writes into a borrowed `mut` buffer, so a program that reads a file into a `[u8]` and uses
> the bytes reports `diverged` (replay correctly surfacing an uncaptured effect). Scalar/handle-only
> FFI replays fine. See OFI-044.

---

## Ownership — [runs: mutation + move/borrow safety; lifetime inference designed]

Borrowing is the default and needs no annotation; `mut` requests a mutable borrow; `move`
transfers ownership. There are no `&`/`&mut` sigils and lifetimes are inferred (MANIFESTO §3.1,
§5b). The qualifier is written **before the binding**, the same way for `self` and named
parameters, because it describes the parameter, not the type.

**Runs today — the mutation mechanics + mutability rule:**

```ember
struct Point { x: int  y: int }

fn bump(mut p: Point) -> int {        // mutable borrow: visible to the caller
    p.x = p.x + 1
    return p.x
}

fn main() -> int {
    var p = Point { x: 1, y: 2 }      // `var` is a mutable binding
    p.x = 10                          // field mutation through a var
    return bump(p)                    // => 11
}
```

A field may be mutated (`p.x = v`, including nested paths `p.a.b = v`) only through a **mutable
place** — a `var` binding or a `mut`/`move` parameter. Mutating through a `let` or a plain
(immutable-borrow) parameter is a compile error. Structs are heap objects, so a `mut` borrow
mutates the caller's value in place (the borrow-model runtime).

**Runs today — the ownership *safety* analysis.** A function-local, sound analysis now enforces:

- **Move semantics.** Heap aggregates (structs) are *move* types: `let q = p`, storing in a
  struct/variant field, a `move` argument, or a return all *transfer* the value. The source is
  then **moved-out**, and using it is an error (use-after-move). Scalars, strings, and enums are
  freely copied. Reassigning a `var` revives it.
- **No aliased mutation.** Because a move consumes the source, `let q = p; p.x = 5` no longer
  silently mutates through two names — `p` is moved and unusable.
- **No escaping borrows.** Returning a *borrowed* parameter is an error (it would leak a
  reference); take it as `move` to return it.
- **Borrow conflicts.** The same value can't be passed to a `mut`/`move` parameter and aliased by
  another argument in the same call (mutable XOR shared).
- **`mut` arguments must be mutable places.** Passing a value to a `mut` (mutable-borrow) parameter
  requires a mutable place — a `var` binding or a `mut`/`move` parameter, possibly through a
  field/element path — never an immutable `let`. Otherwise the callee could mutate a value the caller
  froze with `let` (for reference-like values such as arrays, the write is visible through the `let`).
  A fresh temporary (literal, constructor, call result) is fine. `move` is exempt — it consumes the
  binding, so the caller observes nothing afterward.
- **Control flow.** Branches merge soundly (the same value may be moved in different `if`/`match`
  arms); moving a value inside a loop body is rejected (it would move again next iteration).
- **No partial moves** (moving one field out of a struct) — conservatively rejected.

```ember
struct Point { x: int  y: int }
fn into_x(move p: Point) -> Point { return p }   // `move`: owns it, may return it

fn main() -> int {
    let p = Point { x: 9, y: 0 }
    let q = into_x(p)     // p is moved into the call
    return q.x            // => 9   (using p here would be a compile error)
}
```

**Ownership now holds inside generic bodies too** (MANIFESTO §5f): a type parameter is a **move type
by default** and a generic body is move-checked exactly like concrete code, with the `Copy` bound as
the opt-out (see [Generics](#generics--runs-structs-enums-functions-methods-and-bounds)). **Still
designed, not yet built:** **inferred return lifetimes** — so a borrowed parameter can be returned
without `move` (the §3.1 ergonomic goal). Deterministic **drop/free** is covered in the
[Memory model](#memory-model--runs-structsarrays-freed-stringsenums-reference-counted) below.

---

## Memory model — [runs: structs/arrays freed; strings/enums reference-counted]

Ember reclaims heap memory **deterministically, without a garbage collector** — the manifesto's
"safe without a GC" promise. The discipline follows ownership: **mutable aggregates are uniquely
owned; immutable values are shared.**

- **Structs and arrays (unique owners).** A binding frees its value at scope exit — recursively
  freeing owned fields/elements. Because the move checker forbids aliasing and partial moves,
  there is exactly one owner, so this is a plain free with no bookkeeping. A value that was
  **moved out** is not freed by the original binding (the new owner frees it); a value that is
  **returned** escapes to the caller, which then owns it.

- **Strings and enums (shared, reference-counted).** These are immutable and freely copied, so
  several bindings can name the same heap value. Each holds a counted reference: aliasing one
  bumps the count, releasing one (at scope exit, or when a containing value is freed) drops it,
  and the value is freed only when the last owner goes. Freeing a container recursively releases
  what it holds — an array of strings frees its strings, an enum carrying a payload frees it.

- **`rc struct` (shared, immutable user structs).** Prefix a struct declaration with `rc` to move
  it from the unique-owner class into the shared, reference-counted class — the *same* mechanism
  strings and enums already use. Many bindings may then name one instance (`let b = a` increfs
  instead of moving or deep-copying; `a` stays live), reclaimed at the last owner. The price is
  **deep immutability**: an `rc struct` may never be mutated (no `var` rebinding of its fields, no
  field/element write *through* it, no `mut self`/`move self` methods), and every field must itself
  be immutably shareable — a scalar, string, enum, or another `rc struct`. That restriction is
  exactly what keeps reference counting complete: a shared value that cannot be mutated cannot be
  made to point back at an ancestor, so **no `rc` value can ever close a reference cycle**. It is
  the blessed tool for *shared, immutable, graph-shaped* data — a parsed config held by many
  components, an immutable AST, a persistent (structurally-shared) list or tree. There is no
  in-place mutation, so to "change" one you build a new value (persistent-data-structure style).
  Generic `rc struct`s (`rc struct Box<T>`) are not yet supported — a v1 restriction.

```ember
fn main() -> string {
    let p = Point { x: 1, y: 2 }   // a struct...
    let s = "hello"                // ...and a string
    let t = s                      // t aliases s (refcount 2)
    return t                       // t escapes to the caller; p is freed at the
}                                  // brace, and s releases its reference (one left)
```

```ember
rc struct Config {                 // shared, immutable, reference-counted
    host: string
    port: int
}

fn main() -> int {
    let a = Config { host: "h", port: 80 }
    let b = a                      // a second owner — an incref, NOT a move or a deep copy
    let c = a                      // a third owner; a, b, c all name one heap value
    // a.port = 81                 // compile error: an rc value is immutable
    return a.port + b.port + c.port // a still live; the value frees when the last owner drops
}
```

Reclamation is eager (at the brace, not at program exit), so long-running programs — e.g.
concurrent workers looping over a channel — don't accumulate garbage. The coverage is broad:
values **sent through a channel** are counted (`send` records the channel's reference, `recv`
hands it to the receiver, so the `match recv(ch) { … }` worker loop reclaims each value);
**arguments** are reclaimed by the callee (a temporary passed to a borrowing call is freed there,
a `move` struct parameter is freed when the call returns); and **discarded temporaries** (a
`match` scrutinee, an expression-statement result) are released. Because structs are unique and
shared values are immutable, **no reference cycles can form**, so counting is complete — there is
nothing a tracing collector would reclaim that this misses.

**Deferred (sound — leak-until-exit, never a use-after-free):** values left **unreceived in an
abandoned channel**. (A refcounted value flowing through a **generic** body is now released by the
caller — the earlier erased-`T` over-retain was closed; see [OFI.md](OFI.md) OFI-117.)

---

## Graphics & UI — Flare

Ember has an **immediate-mode UI**, written in Ember over one blessed native dependency (MANIFESTO
§5g). A UI is a *function of state that runs every frame* — no retained widget tree, no callbacks, no
`Rc<RefCell>` graph — the shape that keeps the ownership model out of your way and reads cleanly for a
model. You build with two imports: **`std/draw`** (primitives over the native backend) and
**`std/flare`** (the widget and layout toolkit, layered on `std/ui` and `std/layout`).

**The frame loop.** Ember drives the loop itself; the body *is* the frame.

```ember
import "std/draw"  as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(580, 400, "Hello Flare")
    var f = flare.new()
    loop {
        if draw.closing() { break }     // window closed / Esc
        draw.begin(f.bg())              // clear to the theme background
        f.begin()                       // snapshot input, reset the layout tree
        if f.primary("Click me") {      // a widget returns its event as a value
            println("clicked")
        }
        f.finish()                      // solve layout, paint, record the frame tape
        draw.finish()                   // present, pump OS events
    }
    draw.close()
    return 0
}
```

**The model in four ideas.**

- **Events are return values** — `if f.button("Save") { save() }`. No handlers, no hidden control
  flow: it is *errors-are-values* applied to input.
- **Components are functions** — `fn Counter(mut f: flare.Flare, key: string) { … }`. No JSX, no
  lifecycle; a component takes the `Flare` context and emits widgets.
- **State is yours** — the loop owns plain `var`s; `f.state_int/str/bool/float(key, default)` (paired
  with `f.set_*`) carries per-widget state across frames.
- **Identity is explicit** — `f.key("row{i}") … f.key_clear()` scopes the widget and state ids so
  duplicate-labelled widgets in a list stay distinct.

**Layout is real flexbox**, re-solved every frame by `std/layout`: `f.row`/`f.column` (and the
`_grow` variants), `f.spacer`, `f.strut`, `f.panel_begin`/`f.end`, `f.scroll_begin`/`f.scroll_end`,
with `flare.START`/`CENTER`/`END`/`BETWEEN`/`STRETCH` for alignment.

**Widgets (a sampler, not the whole set):** actions `button`/`primary`/`danger`/`ghost_button`;
navigation `nav_item`/`avatar`; choice `segmented`; text `heading`/`label`/`text_muted`/`divider`;
prose `paragraph`/`rich_text` (inline Markdown)/`markdown` (tables, code blocks, syntax
highlighting); input `text_field`/`text_area`/`submit`; containers `bubble_begin`/`page_begin`/
`splitter`; overlays `modal_begin`/`popover_begin`/`menu_item`; virtualised long lists
`virtual_begin`/`virtual_item`; and a `DockTree` for draggable, tabbed, JSON-persistable docking.

**Animation is deterministic** — a fixed per-frame timestep, so frames stay replayable and
golden-testable: `f.spring(key, target)` eases a value, `f.at(dx, dy) { … } f.end_at()` offsets paint,
and `f.animate_layout(key) { … }` FLIP-animates subtrees that moved. **Theming is data** —
`f.use_dark()`/`f.use_light()` swap a `Style` struct; `f.set_zoom(pct)` (60–220) and `f.zoom_by(d)`
scale the whole UI.

**The backend.** The heavy work — paint, GPU, the OS event pump — is native C, so Ember only
*describes* each frame and 60fps stays reachable on the bytecode VM. The screen is reached through
**one** curated in-tree C library, **raylib**, with a real embedded TrueType font (Inter) baked in for
crisp, zero-install text. The engine hides behind the Ember API, so it stays swappable. Every frame
can also be recorded to a **UI tape** — input, draw commands, and high-level interactions as
JSON-Lines, the same machine-readable shape as the execution tape.

**Build & run.** Graphics is an **opt-in build**, so the default compiler stays dependency-free:

```
make graphics                                   # builds build/emberc-gfx (links raylib)
EMBER_STD=./std build/emberc-gfx --emit=run examples/graphics/17_flare.em
```

**Status — [runs]:** layout, the widgets above, overlays, animation, theming/zoom, virtual lists,
docking, and toasts; `std/ui` widgets even carry contracts. **Not yet:** `checkbox`/`slider` wrapped
into Flare's flexbox layer (use `button`/`segmented` over a `var` meanwhile), real bold/italic faces
(inline `**bold**`/`*italic*` are synthesised from one embedded weight — OFI-077), cross-block text
selection in Markdown, and free-floating windows. The full tour is in
[the book](THE_EMBER_BOOK.md) (ch. 25) and [docs/flare.md](flare.md).

---

## Using the compiler

```
emberc file.em                  # default: print the token stream
emberc --emit=tokens   file.em  # token stream
emberc --emit=ast      file.em  # parsed AST
emberc --emit=bytecode file.em  # bytecode disassembly (with source lines)
emberc --emit=run      file.em  # compile and execute; prints "=> <value>"
emberc --emit=c        file.em  # emit the native C lowering to stdout
emberc -o prog         file.em  # compile to a standalone native binary
emberc --emit=trace    file.em  # execution tape, JSON Lines (alias: --tape)
emberc --emit=check    file.em  # property-check contracts (see Contracts)
emberc --emit=prove    file.em  # statically prove contracts where decidable
emberc --emit=replay   file.em  # record/replay determinism check
emberc --emit=docs     file.em  # render /// doc comments to a Markdown page
emberc --lsp                    # run the language server
emberc --doctor                 # environment / toolchain self-check
```

Combinable flags: **`--release`** elides contract checks (see *Contracts*),
**`--diagnostics=json`** reports compile errors as JSON (see *Diagnostics* below), and
**`--faults=human|agent`** selects the runtime-fault format; **`--version`** and **`--help`** do the
obvious.

Exit codes: `0` success, `64` usage error, `65` source error (lexical/syntax/type/runtime),
`66` unreadable input file.

## Diagnostics — the compiler is a teacher

Compile errors are designed to **explain the fix in terms of your program, not the theory**
(MANIFESTO §3.1/§5). A use-after-move, for instance, names the value, points at where it was
moved, and suggests how to fix it:

```
prog.em:6:12: error: use of 'p' after it was moved
prog.em:6:12: help: a move transfers ownership; pass it without `move` to borrow it instead, or make a copy before the move
prog.em:5:13: note: value moved here
```

Because Ember is designed LLM-first (§5b), diagnostics are also available **as data**: add
**`--diagnostics=json`** and each error is emitted as a JSON object (JSON Lines, on stderr) with
its `file`/`line`/`col`/`message`, optional `near` context, a `help` fix suggestion, and a
secondary `note` location — so a model that wrote the code can parse the error and apply the fix
without scraping text:

```
emberc --emit=run --diagnostics=json prog.em
{"severity":"error","file":"prog.em","line":6,"col":12,"message":"use of 'p' after it was moved","near":null,"help":"a move transfers ownership; …","note":{"line":5,"col":13,"message":"value moved here"}}
```

## The execution tape — [runs]

`emberc --tape file.em` runs the program and writes a **tape**: one JSON object per executed
instruction, in order, to stdout. Each event records the instruction offset, the opcode, the
**source line** it came from, and a snapshot of the value stack at that moment:

```json
{"ip":0,"op":"CONST","line":2,"stack":[]}
{"ip":2,"op":"GET_LOCAL","line":3,"stack":[2]}
{"ip":6,"op":"GT","line":3,"stack":[2,2,1]}
```

It is **observer-only** — recording a tape never changes how the program runs — and costs
effectively nothing when not enabled. The tape is designed to be read by an LLM (or any tool)
to debug a run step by step; it is one of Ember's deliberate LLM-first features, not an
afterthought. Richer semantic events (error propagation, task lifecycle) and the ability to
register your own hook from Ember code will layer onto the same mechanism as those features
land.

---

## Quirks & gotchas

- **No semicolons; newlines terminate.** Break *after* an operator, never before it.
- **`let` is immutable.** Reach for `var` only when you actually reassign.
- **Struct literals are suppressed in `if`/`for`/`match` headers** to keep `{` unambiguous.
- **`Name<T> { … }`** (generic struct literal) is disambiguated from `<` comparison by a
  sound lookahead rule (OFI-002): a generic only when a balanced `<…>` of type-legal tokens is
  immediately followed by `{` — no expression begins with `{`, so `> {` can't continue a comparison.
- **`Self`** (capitalised) is the implementing type inside an interface/struct; `self`
  (lowercase) is the receiver value.
