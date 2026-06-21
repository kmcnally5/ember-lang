// discard_wildcard.em — `_` is a discard wildcard (OFI-095). A bare `_` binding may be
// repeated any number of times in one scope, binds nothing readable, drops an owned value
// exactly once (never leaks), and works as a function parameter too. Reading `_` is a compile
// error (see error_discard_read.em); discarding a linear Ptr still errors (error_discard_ptr_leak.em).

import "std/map" as mp

fn mk(s: string) -> string {
    return s + "!"
}

// Two `_` parameters in one signature no longer collide; neither is readable in the body.
fn add1(_: int, x: int, _: int) -> int {
    return x + 1
}

fn main() -> int {
    var m = mp.Map<string, int>{ buckets: [], count: 0 }
    m.set("a", 1)
    m.set("b", 2)
    m.set("c", 3)

    // Repeated discard in one scope — the exact OFI-095 case (three `let _ =` in a row).
    let _ = m.remove("a")
    let _ = m.remove("b")
    let _ = m.remove("missing")
    println("after removes size={m.size()}")

    // Discard fresh owned temporaries (concatenated strings) — each dropped once, no leak.
    let _ = mk("x")
    let _ = mk("y")
    let _ = mk("z")
    println("discarded three owned strings")

    // `_` as a (repeated) parameter.
    println("add1(_, 41, _) = {add1(9, 41, 9)}")

    return 0
}
