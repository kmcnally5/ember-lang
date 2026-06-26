// errors.em — std/sqlite failure paths surface as Err, never a crash, on the clean `resource` API:
// exec against a missing table returns Err carrying SQLite's message, and a malformed prepare returns
// Err (the failed handle is finalized inside prepare). Needs emberc-db; run via `make test-db`.
import "std/sqlite" as sql


fn work() -> Result<int, string> {
    let db = sql.open(":memory:")?
    // exec against a table that does not exist comes back as Err, not a trap
    match sql.exec(db, "INSERT INTO ghost VALUES(1)") {
        case Ok(n) {
            println("UNEXPECTED ok")
        }
        case Err(e) {
            println("exec_err: {e}")
        }
    }
    // a malformed statement fails to compile: prepare returns Err with a readable message
    match sql.prepare(db, "SELEKT 1") {
        case Ok(st) {
            println("UNEXPECTED prepare ok")
        }
        case Err(e) {
            println("prepare_err: {e}")
        }
    }
    return Ok(0)
}


fn main() -> int {
    match work() {
        case Ok(n) {
            println("done")
            return 0
        }
        case Err(e) {
            println("ERR: {e}")
            return 1
        }
    }
}
