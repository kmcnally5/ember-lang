---
title: std/sqlite — Databases
nav_order: 9
description: Ember's embedded SQL — std/sqlite, backed by a vendored SQLite amalgamation, with connections and statements as compile-time-checked linear handles.
---

# Ember `std/sqlite` — Databases

Ember talks to a real database through **`std/sqlite`**: embedded SQL backed by a **vendored SQLite
amalgamation**. It is the database that fits Ember's empty-dependency-tree rule — a single
public-domain C file, no server, no system package — and it is the most-deployed engine on earth, so
it is also the path of least surprise for a model writing data code.

It is an **opt-in build**, exactly like `std/http` (libcurl) and `std/ui` (raylib): the bindings only
link under `make db`. The default build stays SQL-free, so `make` / `make test` never compile SQLite.

```ember
import "std/sqlite" as sql
```

```
build/emberc-db --emit=run myprogram.em      # the database build (make db)
```

## Why vendored, not linked

SQLite is the one engine designed to be embedded as source. The whole library is two checked-in files
in [`third_party/sqlite/`](https://github.com/kmcnally5/ember-lang/tree/main/third_party/sqlite)
(`sqlite3.c` + `sqlite3.h`), compiled once into the compiler. So `make db` works on any machine — macOS
or Linux — with **no install step at all**, which upholds Ember's "zero install-time dependencies /
deterministic build" value *better* than curl or raylib can (those must be system libraries; SQLite
need not be). The vendored copy is compiled `THREADSAFE=0` (the VM running it is single-threaded) with
the extension loader omitted, so the link pulls in nothing beyond libc/libm. Provenance, version, and
the update procedure live in the directory's `README.md`.

## Connections and statements are linear handles

A **connection** is a `resource struct Db` and a **prepared statement** a `resource struct Stmt`
([OFI-122](OFI.md)) — each *owns* its underlying SQLite handle, and its `drop` closes it. So the
compiler guarantees **every connection is closed and every statement finalized exactly once, on every
path — automatically.** The single most common database bug (a leaked connection or an un-finalized
statement) is impossible here, and there is **no ceremony**: `open`/`prepare` return a `Result`, and a
handle closes itself when its binding leaves scope — including on an early `?`-return or an error path.

```ember
fn run() -> Result<int, string> {
    let db = sql.open("notes.db")?                 // Db — auto-CLOSES at scope exit (or on any `?`)
    let _ = sql.exec(db, "CREATE TABLE IF NOT EXISTS note(id INTEGER PRIMARY KEY, body TEXT)")?
    let _ = sql.exec(db, "INSERT INTO note(body) VALUES('hello'), ('world')")?
    let st = sql.prepare(db, "SELECT id, body FROM note ORDER BY id")?   // Stmt — auto-FINALIZES
    loop {
        if !sql.step(st)? { break }                // false = no more rows; `?` propagates a real error
        println("{sql.column_int(st, 0)}: {sql.column_text(st, 1)}")
    }
    return Ok(0)
}                                                   // st finalized, then db closed — automatically

fn main() -> int {
    match run() {
        case Ok(n)  { return 0 }
        case Err(e) { println("db error: {e}"); return 1 }
    }
}
```

This is the payoff of [`resource` types](design/ptr-owning.md): the handle manages itself. There is no
`close()`, `finalize()`, or `ok()` to call, and no owner-borrows-worker dance — `?` "just works",
because an owned `Db`/`Stmt` drops on the early-return path the same as on the normal one.

## Error model

Failures route through Ember's two error surfaces. `open` and `prepare` return `Result<Db>` /
`Result<Stmt>` (so `?` checks them); `exec` returns `Result<int, string>` (rows changed) and `step`
returns `Result<bool, string>` (`Ok(true)` = a row is ready, `Ok(false)` = finished, `Err` = a real
error). An unhandled error that reaches `main` renders as a [Fault](faults.md).

## API

`Db` and `Stmt` are `resource struct`s — there is no manual `close`/`finalize`/`ok`; the compiler drops
them (closing the connection / finalizing the statement) for you, on every path.

| Function | Purpose |
|---|---|
| `open(path) -> Result<Db, string>` | Open/create the database; the `Db` closes itself at scope exit. `":memory:"` for a private in-memory DB. |
| `exec(db, sql) -> Result<int, string>` | Run statement(s) returning no rows (DDL / writes); `Ok(rows-changed)`. Multi-statement. |
| `prepare(db, sql) -> Result<Stmt, string>` | Compile the first statement; the `Stmt` finalizes itself at scope exit. |
| `bind_int / bind_f64 / bind_text / bind_null(st, idx, val)` | Bind a value to parameter `idx` (1-based). |
| `step(st) -> Result<bool, string>` | Advance to the next row. `Ok(true)` = row, `Ok(false)` = done. |
| `reset(st) -> int` | Rewind + clear bindings to reuse a compiled statement. |
| `column_count(st) -> int` | Result columns in the current row. |
| `column_type(st, col) -> int` | Storage class: 1 INTEGER, 2 FLOAT, 3 TEXT, 4 BLOB, 5 NULL. |
| `column_is_null(st, col) -> bool` | Is column `col` a true SQL NULL? |
| `column_int / column_f64 / column_text(st, col)` | Read column `col` (0-based) of the current row. |
| `column_name(st, col) -> string` | The name of result column `col`. |
| `changes(db) -> int` | Rows changed by the most recent statement. |
| `last_insert_id(db) -> int` | ROWID of the most recent INSERT. |

## What this is, and what is planned

This is the **resource-based binding** — the complete, sound foundation. The owning-handle ergonomics
([`resource` types](design/ptr-owning.md), OFI-122) are here: `Db`/`Stmt` close themselves, so the API
is `?`-clean with no `close`/`finalize`. Two layers are still planned on top:

- **Ergonomic row helpers** — `query(db, sql, params) -> Result<[Row], string>` and a parametrised
  `exec`, so a simple SELECT needs no prepare/step/column loop. The open design question is the `Row`
  representation (`Map<string, _>` vs a `DbValue` enum).
- **Compile-time-checked SQL** — because Ember owns the compiler and SQL literals are usually
  constants, the query could be parsed at compile time and its columns/parameters checked against
  Ember usage, so `column_int` on a `TEXT` column, or a typo'd column name, becomes a *compile error*.
  This is Ember's verification-and-determinism moat applied to data access.

The binding runs on the **bytecode VM** (`make db`); native-backend (`emberc -o`) support — wiring the
SQLite externs into the runtime library — is a tracked follow-up ([OFI-143](OFI.md)).
