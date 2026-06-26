// resource_shapes.em — OFI-122 runtime "drops exactly once on every path", swept across the
// control-flow shapes Ledger fuzzes for a linear Ptr (reassign, conditional, early-return, loop,
// match-borrow, reverse-order), run on BOTH backends (VM == binary). Each drop is observable
// (println), so a double-drop, a missed drop, or a VM≠native ORDER divergence changes the output and
// the differential harness catches it. (Memory-safety of the same is gated by the reclaim double-drop
// detector + the resource regressions; this pins the observable behavior + cross-backend agreement.)
resource struct R {
    id: int

    fn drop(self) {
        println("drop {self.id}")
    }
}

fn reassign() -> int {
    var r = R { id: 1 }
    r = R { id: 2 }              // the old R{1} drops here, on the overwrite
    return 0
}

fn conditional(c: bool) -> int {
    if c {
        let a = R { id: 10 }
        return a.id             // a drops on this early return out of the if-branch
    }
    let b = R { id: 11 }
    return b.id
}

fn early(c: bool) -> int {
    let r = R { id: 20 }
    if c {
        return 0                // r drops on the early-return path…
    }
    return r.id                 // …and on the fall-through path (exactly once on each)
}

fn loop_drop() -> int {
    var i = 0
    var total = 0
    loop {
        if i == 3 { break }
        let r = R { id: 100 + i }   // created AND dropped each iteration
        total = total + r.id
        i = i + 1
    }
    return total
}

fn match_borrow(res: Result<R, string>) -> int {
    match res {
        case Ok(r) { return r.id }   // borrow-read (no clone); the owning scrutinee drops the R
        case Err(e) { return 0 - 1 }
    }
}

fn two() -> int {
    let a = R { id: 7 }
    let b = R { id: 8 }
    return a.id + b.id          // drops b then a (reverse declaration order)
}

fn main() -> int {
    println("-- reassign --")
    let _ = reassign()
    println("-- conditional true --")
    let _ = conditional(true)
    println("-- early false --")
    let _ = early(false)
    println("-- loop --")
    let _ = loop_drop()
    println("-- match Ok --")
    let _ = match_borrow(Ok(R { id: 9 }))
    println("-- two reverse --")
    let _ = two()
    return 0
}
