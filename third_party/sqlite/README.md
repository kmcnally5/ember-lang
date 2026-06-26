# Vendored SQLite amalgamation

This directory holds the **public-domain SQLite amalgamation** — the entire engine as a single
translation unit — that backs `std/sqlite` (the `make db` build). SQLite is the one database that
fits Ember's empty-dependency-tree rule: no server, no system package, no transitive dependencies,
just two checked-in files compiled into the compiler.

| | |
|---|---|
| **Version** | 3.53.2 |
| **Files** | `sqlite3.c` (amalgamation), `sqlite3.h` (public API header) |
| **Source** | <https://www.sqlite.org/2026/sqlite-amalgamation-3530200.zip> |
| **Zip SHA3-256** | `81142986038e18f96c4a54e1a72562ae17e502a916f2a7701eff43388cbf1a40` |
| **License** | Public Domain (<https://www.sqlite.org/copyright.html>) |

The CLI shell (`shell.c`) and the extension header (`sqlite3ext.h`) from the zip are **not**
vendored — we only need the library itself.

## How it is built

`build/sqlite3.o` is compiled once from `sqlite3.c` by the `Makefile`, with third-party code held
to `-Wall -Wextra` (not our `-Werror`) and these options:

- `-DSQLITE_THREADSAFE=0` — the Ember VM that runs `std/sqlite` is single-threaded, so the mutex
  layer is omitted (no `-lpthread` dependency). Revisit if `std/sqlite` is ever used from parallel
  fibers sharing one connection.
- `-DSQLITE_OMIT_LOAD_EXTENSION=1` — we never load runtime extensions, so this drops the `dlopen`
  reference and keeps the link dependency-free (no `-ldl`) across macOS and Linux.

The C FFI wrappers that expose the engine to Ember live in `src/cextern.c` under `#if EMBER_SQLITE`;
the Ember-level API is `std/sqlite.em`.

## Updating

1. Download the new amalgamation zip from <https://www.sqlite.org/download.html>.
2. Verify its SHA3-256 against the value published on that page.
3. Replace `sqlite3.c` and `sqlite3.h`, and update the table above.
4. `make db && make test-db` — the regression suite must stay green.
