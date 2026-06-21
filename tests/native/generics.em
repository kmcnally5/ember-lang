// Native backend (M3a) differential test: erased generics + Option/Result + the `?` operator.
// A generic function lowers to ONE C function over the uniform boxed Value (no per-type
// specialization); Option/Result are boxed enums; `?` unwraps the success payload or returns
// the Err/None early (running the function's owning-local drops first). Covers `?` on BOTH
// Result (error propagation) and Option (None propagation), generics over int and string, and
// a generic that returns an Option.
fn id<T>(move x: T) -> T {
    return x
}

fn wrap<T>(move x: T) -> Option<T> {
    return Some(x)
}

fn checked_div(a: int, b: int) -> Result<int, int> {
    if b == 0 {
        return Err(0)
    }
    return Ok(a / b)
}

fn chain(a: int, b: int) -> Result<int, int> {
    let q = checked_div(a, b)?
    return Ok(q + 100)
}

fn maybe(n: int) -> Option<int> {
    if n < 0 {
        return None
    }
    return Some(n)
}

fn doubled(n: int) -> Option<int> {
    let v = maybe(n)?
    return Some(v * 2)
}

fn main() -> int {
    let a = id(42)
    let s = id("hi")
    println(s)
    println("a = {a}")

    let o = wrap(7)
    match o {
        case Some(n) { println("some {n}") }
        case None    { println("none") }
    }

    match chain(20, 4) {
        case Ok(v)  { println("ok {v}") }
        case Err(e) { println("err {e}") }
    }
    match chain(20, 0) {
        case Ok(v)  { println("ok {v}") }
        case Err(e) { println("err {e}") }
    }

    match doubled(5) {
        case Some(v) { println("doubled {v}") }
        case None    { println("neg") }
    }
    match doubled(-1) {
        case Some(v) { println("doubled {v}") }
        case None    { println("neg") }
    }
    return a
}
