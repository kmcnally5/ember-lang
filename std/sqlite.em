// std/sqlite — embedded SQL over Ember's FFI, backed by the vendored SQLite amalgamation. SQLite is
// the one database that fits Ember's empty-dependency-tree rule: a single public-domain C file, no
// server, no system package. Only links under the database build (`make db`); a default-build program
// that imports this fails to link, exactly as std/ui needs the graphics build and std/http the net one.
//
// A CONNECTION (`Db`) and a PREPARED STATEMENT (`Stmt`) are `resource struct`s (OFI-122): each owns its
// opaque SQLite handle and its `drop` closes it, so the compiler guarantees every connection is closed
// and every statement finalized EXACTLY ONCE, on every path — automatically. The single most common
// database bug (a leaked connection or an unfinalized statement) is impossible here, with no ceremony:
// `open` and `prepare` return a `Result<Db>` / `Result<Stmt>` (so `?` checks failure), and the handle
// closes itself when its binding leaves scope, including on an early `?`-return or an error path.
//
//   import "std/sqlite" as sql
//
//   fn run() -> Result<int, string> {
//       let db = sql.open("notes.db")?                 // Db — auto-CLOSES at scope exit (or on any `?`)
//       let _ = sql.exec(db, "CREATE TABLE IF NOT EXISTS note(id INTEGER PRIMARY KEY, body TEXT)")?
//       let _ = sql.exec(db, "INSERT INTO note(body) VALUES('hello'), ('world')")?
//       let st = sql.prepare(db, "SELECT id, body FROM note ORDER BY id")?   // Stmt — auto-FINALIZES
//       loop {
//           if !sql.step(st)? { break }                // false = no more rows; `?` propagates a real error
//           println("{sql.column_int(st, 0)}: {sql.column_text(st, 1)}")
//       }
//       return Ok(0)
//   }                                                   // st finalized, then db closed — automatically
//
//   fn main() -> int {
//       match run() {
//           case Ok(n)  { return 0 }
//           case Err(e) { println("db error: {e}"); return 1 }
//       }
//   }

// The C bindings (the vendored SQLite engine, registered in src/cextern.c under EMBER_SQLITE). The
// resources + wrappers below give the module a clean, stutter-free API (sql.open, not sql.sqlite_open),
// own the raw handles, and fold the raw result codes into Ember's Result/bool error model.
extern "c" {
    fn sqlite_open(path: string) -> Ptr
    fn sqlite_close(move h: Ptr) -> i64
    fn sqlite_errcode(h: Ptr) -> i64
    fn sqlite_errmsg(h: Ptr) -> string
    fn sqlite_errstr(code: i64) -> string
    fn sqlite_exec(h: Ptr, sql: string) -> i64
    fn sqlite_prepare(h: Ptr, sql: string) -> Ptr
    fn sqlite_bind_int(st: Ptr, idx: i64, val: i64) -> i64
    fn sqlite_bind_f64(st: Ptr, idx: i64, val: f64) -> i64
    fn sqlite_bind_text(st: Ptr, idx: i64, val: string) -> i64
    fn sqlite_bind_null(st: Ptr, idx: i64) -> i64
    fn sqlite_step(st: Ptr) -> i64
    fn sqlite_reset(st: Ptr) -> i64
    fn sqlite_column_count(st: Ptr) -> i64
    fn sqlite_column_type(st: Ptr, col: i64) -> i64
    fn sqlite_column_int(st: Ptr, col: i64) -> i64
    fn sqlite_column_f64(st: Ptr, col: i64) -> f64
    fn sqlite_column_text(st: Ptr, col: i64) -> string
    fn sqlite_column_name(st: Ptr, col: i64) -> string
    fn sqlite_finalize(move st: Ptr) -> i64
    fn sqlite_changes(h: Ptr) -> i64
    fn sqlite_last_insert_rowid(h: Ptr) -> i64
}

// SQLite step() result codes and the column storage class for NULL, named so the wrappers read clearly.
let _SQLITE_ROW = 100
let _SQLITE_DONE = 101
let _SQLITE_NULL = 5


// Db OWNS an open SQLite connection. It is a `resource`: its handle closes itself (sqlite_close) when
// the Db's binding leaves scope, on every path — so a connection can never leak. Obtain one with open();
// pass it (borrowed) to exec/prepare/etc.; never close it by hand (the compiler reclaims it for you).
resource struct Db {
    conn: Ptr
    fn drop(self) {
        let _ = sqlite_close(self.conn)
    }
}


// Stmt OWNS a compiled prepared statement. It is a `resource`: its handle finalizes itself
// (sqlite_finalize) when the Stmt's binding leaves scope, on every path — so a statement can never be
// left un-finalized. Obtain one with prepare(); drive it with bind_*/step/column_*.
resource struct Stmt {
    handle: Ptr
    fn drop(self) {
        let _ = sqlite_finalize(self.handle)
    }
}


// open connects to the database file at `path`, creating it if absent. Returns Ok(Db) — a connection
// that closes itself at scope exit — or Err(message) if the open failed (e.g. an unwritable path).
fn open(path: string) -> Result<Db, string> {
    let conn = sqlite_open(path)
    if sqlite_errcode(conn) != 0 {
        let msg = sqlite_errmsg(conn)
        let _ = sqlite_close(conn)
        return Err(msg)
    }
    return Ok(Db { conn: conn })
}


// exec runs one or more semicolon-separated statements that return no rows — schema (CREATE/DROP) and
// writes (INSERT/UPDATE/DELETE) — in a single call. Returns Ok(rows-changed) or Err(message). This is
// the one-liner for migrations and parameterless writes; to bind parameters or read rows, prepare().
fn exec(db: Db, sql: string) -> Result<int, string> {
    let rc = sqlite_exec(db.conn, sql)
    if rc != 0 {
        return Err(sqlite_errmsg(db.conn))
    }
    return Ok(sqlite_changes(db.conn))
}


// prepare compiles the FIRST statement of `sql` into a prepared statement. Returns Ok(Stmt) — a
// statement that finalizes itself at scope exit — or Err(message) on a compile error. Only the first
// statement is compiled; multi-statement scripts go through exec(). Bind with bind_*, drive with step().
fn prepare(db: Db, sql: string) -> Result<Stmt, string> {
    let handle = sqlite_prepare(db.conn, sql)
    if sqlite_errcode(db.conn) != 0 {
        let msg = sqlite_errmsg(db.conn)
        let _ = sqlite_finalize(handle)
        return Err(msg)
    }
    return Ok(Stmt { handle: handle })
}


// bind_int binds a 64-bit integer to parameter `idx` (1-based — the first `?` is 1). Returns the
// SQLite result code (0 = OK); a non-zero code means a misused index or type, rare in correct code.
fn bind_int(st: Stmt, idx: int, val: int) -> int {
    return sqlite_bind_int(st.handle, idx, val)
}


// bind_f64 binds a floating-point value to parameter `idx` (1-based). Returns the SQLite result code.
fn bind_f64(st: Stmt, idx: int, val: float) -> int {
    return sqlite_bind_f64(st.handle, idx, val)
}


// bind_text binds a text value to parameter `idx` (1-based). SQLite copies the bytes, so the string
// need not outlive the call. Returns the SQLite result code.
fn bind_text(st: Stmt, idx: int, val: string) -> int {
    return sqlite_bind_text(st.handle, idx, val)
}


// bind_null binds SQL NULL to parameter `idx` (1-based). Returns the SQLite result code.
fn bind_null(st: Stmt, idx: int) -> int {
    return sqlite_bind_null(st.handle, idx)
}


// step advances a prepared statement to its next result row. Returns Ok(true) when a row is ready
// (read it with the column_* accessors), Ok(false) when the statement has finished, or Err(message)
// on a real error. The Ok(bool) drives the loop; the `?` propagates genuine failures:
//   loop { if !sql.step(st)? { break }  /* … read the row … */ }
fn step(st: Stmt) -> Result<bool, string> {
    let rc = sqlite_step(st.handle)
    if rc == _SQLITE_ROW {
        return Ok(true)
    }
    if rc == _SQLITE_DONE {
        return Ok(false)
    }
    return Err(sqlite_errstr(rc))
}


// reset rewinds a statement to its initial state and clears its parameter bindings, so it can be
// re-bound and re-stepped. Reusing one compiled statement across a loop of INSERTs is far cheaper
// than preparing a fresh one each time. Returns the SQLite result code.
fn reset(st: Stmt) -> int {
    return sqlite_reset(st.handle)
}


// column_count returns the number of result columns in the current row.
fn column_count(st: Stmt) -> int {
    return sqlite_column_count(st.handle)
}


// column_type returns the storage class of column `col` (0-based) in the current row: 1 INTEGER,
// 2 FLOAT, 3 TEXT, 4 BLOB, 5 NULL. Use it to tell a real SQL NULL from an empty string or a zero.
fn column_type(st: Stmt, col: int) -> int {
    return sqlite_column_type(st.handle, col)
}


// column_is_null reports whether column `col` (0-based) of the current row holds SQL NULL.
fn column_is_null(st: Stmt, col: int) -> bool {
    return sqlite_column_type(st.handle, col) == _SQLITE_NULL
}


// column_int returns column `col` (0-based) of the current row as a 64-bit integer.
fn column_int(st: Stmt, col: int) -> int {
    return sqlite_column_int(st.handle, col)
}


// column_f64 returns column `col` (0-based) of the current row as a floating-point value.
fn column_f64(st: Stmt, col: int) -> float {
    return sqlite_column_f64(st.handle, col)
}


// column_text returns column `col` (0-based) of the current row as text. A SQL NULL comes back as the
// empty string — call column_is_null() first when the distinction matters.
fn column_text(st: Stmt, col: int) -> string {
    return sqlite_column_text(st.handle, col)
}


// column_name returns the name of result column `col` (0-based), as named in the SELECT.
fn column_name(st: Stmt, col: int) -> string {
    return sqlite_column_name(st.handle, col)
}


// changes returns the number of rows inserted, updated, or deleted by the most recent statement on
// `db`. (exec() already returns this; reach for it after stepping a prepared write.)
fn changes(db: Db) -> int {
    return sqlite_changes(db.conn)
}


// last_insert_id returns the ROWID assigned to the most recent successful INSERT on `db` — typically
// the auto-incremented INTEGER PRIMARY KEY of the row just written.
fn last_insert_id(db: Db) -> int {
    return sqlite_last_insert_rowid(db.conn)
}
