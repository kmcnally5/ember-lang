// basic.em — std/sqlite CRUD over an in-memory database (deterministic, no files), on the clean
// `resource`-based API (OFI-122). Exercises exec (multi-statement schema + seed), a prepared
// parametrised INSERT with a bound NULL, last_insert_id / changes, and a SELECT loop reading every
// column kind plus a true SQL NULL. The Db connection and both Stmt statements close/finalize
// THEMSELVES at scope exit — no close()/finalize() in sight. Needs emberc-db; run via `make test-db`.
import "std/sqlite" as sql


// work does the whole job. `db`, `ins`, and `sel` are resources: each closes/finalizes itself at the
// closing brace (in reverse order), so an early `?` can never leak a handle and there is no ceremony.
fn work() -> Result<int, string> {
    let db = sql.open(":memory:")?
    // schema + two seed rows in a single multi-statement exec (exact-binary prices keep output stable)
    let _ = sql.exec(db, "CREATE TABLE item(id INTEGER PRIMARY KEY, name TEXT, qty INTEGER, price REAL); INSERT INTO item(name, qty, price) VALUES('apple', 3, 0.5); INSERT INTO item(name, qty, price) VALUES('pear', 7, 0.25)")?
    println("created+seeded")
    // a third row through a prepared statement, with a bound SQL NULL for qty
    let ins = sql.prepare(db, "INSERT INTO item(name, qty, price) VALUES(?, ?, ?)")?
    let _ = sql.bind_text(ins, 1, "mystery")
    let _ = sql.bind_null(ins, 2)
    let _ = sql.bind_f64(ins, 3, 2.25)
    let _ = sql.step(ins)?
    println("last_id={sql.last_insert_id(db)} changes={sql.changes(db)}")
    let sel = sql.prepare(db, "SELECT id, name, qty, price FROM item ORDER BY id")?
    println("cols={sql.column_count(sel)}")
    loop {
        if !sql.step(sel)? { break }
        let id = sql.column_int(sel, 0)
        let name = sql.column_text(sel, 1)
        var qty = "NULL"
        if !sql.column_is_null(sel, 2) {
            qty = "{sql.column_int(sel, 2)}"
        }
        let price = sql.column_f64(sel, 3)
        println("{id} {name} qty={qty} price={price} type2={sql.column_type(sel, 2)}")
    }
    return Ok(0)
}


fn main() -> int {
    match work() {
        case Ok(n) {
            println("ok")
            return 0
        }
        case Err(e) {
            println("ERR: {e}")
            return 1
        }
    }
}
