// M5d fixture for the self-hosted C-emit backend: arrays. Exercises array literals (`em_array`), empty
// arrays from an annotation, indexing (`em_index`), `.len()` / `.append()`, scalar bindings derived from
// an array (`let n = xs.len()`, `let x = xs[i]`), array params (a BORROW), `for x in xs` over a param /
// local / literal (the literal's temp dropped after the loop), returning an owned array (a move that nils
// the slot), array `var` reassignment (drop-old-then-store), an array passed to a call (a borrow), an
// owning-temp array literal as a call argument (dropped after the call), and `.len()` on a temp receiver.
// Byte-identical to stage-0 `emberc --emit=c` (gated, Stage 6 of make selfhost).
fn make(n: int) -> [int] {
    var xs: [int] = []
    var i = 0
    loop {
        if i >= n {
            break
        }
        xs.append(i * i)
        i = i + 1
    }
    return xs
}


fn sum(xs: [int]) -> int {
    var t = 0
    var i = 0
    loop {
        if i >= xs.len() {
            break
        }
        t = t + xs[i]
        i = i + 1
    }
    return t
}


fn weighted(xs: [int]) -> int {
    var t = 0
    for (i, x) in xs {
        t = t + i * x
    }
    return t
}


fn over_literal() -> int {
    var t = 0
    for v in [3, 5, 7, 9] {
        t = t + v
    }
    return t
}


fn flags() -> int {
    let bs = [true, false, true, true]
    var c = 0
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        if bs[i] {
            c = c + 1
        }
        i = i + 1
    }
    return c
}


fn analyze(xs: [int]) -> int {
    let n = xs.len()
    var acc = 0
    var i = 0
    loop {
        if i >= n {
            break
        }
        let v = xs[i]
        acc = acc + v
        i = i + 1
    }
    return acc
}


fn reassign() -> int {
    var xs = [1, 2]
    xs = [3, 4, 5, 6]
    return xs.len()
}


fn squares(n: int) -> int {
    var xs: [int] = []
    var i = 0
    loop {
        if i >= n {
            break
        }
        xs.append(0)
        i = i + 1
    }
    var j = 0
    loop {
        if j >= n {
            break
        }
        xs[j] = j * j
        j = j + 1
    }
    return sum(xs)
}


fn main() -> int {
    let xs = make(5)
    let direct = [10, 20, 30].len()
    let viacall = make(4)[2]
    let a = sum(xs) + weighted(xs) + over_literal() + flags()
    let b = analyze(xs) + reassign() + two([7, 8], [9, 10, 11])
    return a + b + direct + viacall + squares(6)
}


fn two(a: [int], b: [int]) -> int {
    return a.len() + b.len() + a[0] + b[0]
}
