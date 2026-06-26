// resource_lifecycle.em — OFI-122 `resource struct` end to end, run on BOTH backends (VM == binary).
// Exercises the headline: a `Result<Db>` checked open, `?`-extraction (em_enum_take MOVES the payload
// out, so it drops exactly once — not the double-drop the OFI-062/063 native tail had), a borrow into
// a worker, automatic scope-exit `drop` in reverse declaration order, and the Err path (no Db created,
// no drop). The drops are observable (println), so any double-drop / missed drop / VM≠native order
// divergence changes the output — and the differential harness compares the two backends.
resource struct Db {
    id: int

    fn drop(self) {
        println("close db {self.id}")
    }
}

fn open(id: int, ok: bool) -> Result<Db, string> {
    if !ok {
        return Err("open failed")
    }
    return Ok(Db { id: id })
}

fn use_db(db: Db) -> int {
    return db.id
}

fn run(ok: bool) -> Result<int, string> {
    let db = open(5, ok)?
    let x = use_db(db)
    return Ok(x)
}

fn pair() -> int {
    let a = Db { id: 1 }
    let b = Db { id: 2 }
    return a.id + b.id
}

fn main() -> int {
    match run(true) {
        case Ok(n) { println("ok {n}") }
        case Err(e) { println("err {e}") }
    }
    match run(false) {
        case Ok(n) { println("ok {n}") }
        case Err(e) { println("err {e}") }
    }
    println("pair sum {pair()}")
    return 0
}
