// persist.em — proves data reaches DISK *and* that a `resource` Db's auto-`drop` really closes (and
// flushes) the connection: write rows through one Db, let it close itself at the end of write_phase,
// then open a SECOND, independent Db on the same file and read them back. If the auto-close did not
// happen, the fresh connection would not see the committed rows. The write first normalises the table
// (CREATE IF NOT EXISTS + DELETE) so the run is deterministic. Needs emberc-db; run via `make test-db`.
import "std/sqlite" as sql


// write_phase opens a connection, writes three rows, and returns — the Db closes itself at the brace.
fn write_phase(path: string) -> Result<int, string> {
    let db = sql.open(path)?
    let _ = sql.exec(db, "CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT)")?
    let _ = sql.exec(db, "DELETE FROM kv")?
    let _ = sql.exec(db, "INSERT INTO kv VALUES('one','1'),('two','2'),('three','3')")?
    return Ok(0)
}


// read_phase opens a BRAND-NEW connection to the same file and reads — proving the data persisted.
fn read_phase(path: string) -> Result<int, string> {
    let db = sql.open(path)?
    let st = sql.prepare(db, "SELECT k, v FROM kv ORDER BY k")?
    loop {
        if !sql.step(st)? { break }
        println("{sql.column_text(st, 0)}={sql.column_text(st, 1)}")
    }
    return Ok(0)
}


fn main() -> int {
    let path = "/tmp/ember_sqlite_persist_test.db"
    match write_phase(path) {
        case Ok(n) { }
        case Err(e) {
            println("write ERR: {e}")
            return 1
        }
    }
    match read_phase(path) {
        case Ok(n) {
            println("persisted ok")
            return 0
        }
        case Err(e) {
            println("read ERR: {e}")
            return 1
        }
    }
}
