// clock_builtin.em — `clock()` returns a monotonic time in seconds (a float), for
// timing. Its absolute value is non-deterministic, so the test checks only the
// properties that always hold: it is non-negative, and successive reads never go
// backwards (an elapsed interval is >= 0).
fn work(n: int) -> int {
    var s = 0
    var i = 0
    loop {
        if i == n { return s }
        s = s + i
        i = i + 1
    }
    return s
}

fn main() -> int {
    let start = clock()
    let r = work(100000)
    let elapsed = clock() - start
    if start >= 0.0 && elapsed >= 0.0 && r == 4999950000 {
        return 1
    }
    return 0
}
