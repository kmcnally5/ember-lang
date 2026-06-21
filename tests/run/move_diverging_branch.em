// move_diverging_branch.em — OFI-010: a branch that diverges (always returns /
// breaks / continues) does not move-poison the code after an `if` or `match`. A
// value moved only on a returning path is still live on the path that falls
// through. This is what makes the build-and-return-a-collection loop natural: the
// early `return acc` no longer makes the following `acc.append` a use-after-move.
struct P { x: int }

enum Choice { Take  Keep }

fn eat(move p: P) -> int {
    return p.x
}

fn pick(cond: bool) -> int {
    let s = P { x: 7 }
    if cond { return eat(s) }       // diverges; s untouched on the fall-through
    return s.x
}

fn via_match(ch: Choice) -> int {   // the same rule applies to a `match` arm
    let s = P { x: 7 }
    match ch {
        case Take { return eat(s) } // diverges; the Keep path leaves s live
        case Keep { }
    }
    return s.x
}

fn fill(n: int) -> [int] {
    var acc: [int] = []
    var k = 1
    loop {
        if k > n { return acc }     // diverging early return; acc still owned below
        acc.append(k * k)
        k = k + 1
    }
    return acc
}

fn main() -> int {
    let squares = fill(4)           // [1, 4, 9, 16]
    var total = 0
    var i = 0
    loop {
        if i == squares.len() { break }
        total = total + squares[i]
        i = i + 1
    }
    return pick(true) + pick(false) + via_match(Take) + via_match(Keep) + total
    //     7           + 7           + 7               + 7               + 30 = 58
}
