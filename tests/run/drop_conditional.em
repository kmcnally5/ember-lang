// drop_conditional.em — a struct moved on only *some* paths is still reclaimed
// correctly. `s` is moved into `eat` on the true branch and merely read on the
// false branch. At scope exit the drop fires, but on the moved path the slot was
// nilled when the value left, so the free is a no-op there; on the unmoved path
// it frees `s`. Either way the struct is freed exactly once (no leak, no double
// free), which the result proves end to end.
struct S { v: int }

fn eat(move s: S) -> int {
    return s.v
}

fn pick(cond: bool) -> int {
    let s = S { v: 5 }
    var r = 0
    if cond {
        r = eat(s)          // moved here
    } else {
        r = s.v             // read here
    }
    return r
}

fn main() -> int {
    return pick(true) + pick(false)     // 5 + 5 = 10
}
