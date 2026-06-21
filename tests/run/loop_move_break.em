// tests/run/loop_move_break.em — regression for OFI-074: the "value moved inside a loop body" guard
// must NOT fire when the move is followed by an unconditional break/return, because the move can't
// reach a back-edge (there is no next iteration). The guard now tracks the moved-state at the actual
// back-edges (continue points + a reachable fall-through), not the body-end state. Covers both `loop`
// and `for`. The sound converse (a move that DOES recur) stays a compile error — see
// error_loop_move_recur.em.
struct Box { v: int }


fn take(move b: Box) -> int {
    return b.v
}


fn main() -> int {
    var total = 0
    var a = Box { v: 7 }
    loop {                       // move then UNCONDITIONAL break → move never recurs → must compile
        total = total + take(a)
        break
    }
    var b = Box { v: 100 }
    for i in 0..5 {              // same, in a `for` body
        total = total + take(b)
        break
    }
    print("total={total}\n")     // 7 + 100 = 107
    return 0
}
