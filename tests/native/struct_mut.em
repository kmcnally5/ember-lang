// Native backend (M2b) differential test: struct field mutation (`c.n = ...`, reading
// the old field in the new value) and reassigning an owned struct `var` (the previous
// value is dropped before the new one is stored — a leak the stdout diff can't see, but
// a double-free would crash).

struct Counter {
    n: int
}


fn main() -> int {
    var c = Counter { n: 0 }
    c.n = 10
    c.n = c.n + 5
    var p = Counter { n: 100 }
    p = Counter { n: 200 }
    return c.n + p.n
}
