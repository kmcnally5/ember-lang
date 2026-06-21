// fn_values.em — first-class function values: a named function has type
// fn(params)->ret, can be passed as an argument, stored in a local, and called.
// At runtime a function value is a closure (here with zero captures); the call goes
// through OP_CALL_CLOSURE. Lambdas (with capture) build on this.
fn double(x: int) -> int { return x * 2 }
fn inc(x: int) -> int { return x + 1 }
fn apply(f: fn(int) -> int, x: int) -> int { return f(x) }
fn twice(f: fn(int) -> int, x: int) -> int { return f(f(x)) }
fn pick(up: bool) -> fn(int) -> int {
    if up { return inc }
    return double
}
fn main() -> int {
    let g = double                 // a function value held in a local
    let a = apply(double, 5)       // 10
    let b = apply(inc, 5)          // 6
    let c = twice(double, 3)       // 12  (f(f(x)))
    let d = g(7)                   // 14
    let e = pick(true)(9)          // 10  (a function value returned, then called)
    return a + b + c + d + e       // 10 + 6 + 12 + 14 + 10 = 52
}
