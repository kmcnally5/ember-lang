// tests/run/error_loop_move_recur.em — the SOUND converse of OFI-074: a value moved on a path that
// reaches the loop's back-edge (here: move, then only a CONDITIONAL break, so the else path falls
// through and re-iterates) WOULD be moved again next iteration — this must stay a compile error.
struct Box { v: int }


fn take(move b: Box) -> int {
    return b.v
}


fn main() -> int {
    var b = Box { v: 1 }
    var r = 0
    loop {
        r = take(b)
        if r > 9 {
            break
        }
    }
    return r
}
