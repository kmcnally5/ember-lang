// 07_contracts.em — executable contracts (MANIFESTO §5e), Ember's flagship LLM-first
// feature. A function states its precondition (`requires`) and postcondition
// (`ensures`, which may name `result`, the return value) right alongside the
// signature. Debug builds check them at runtime; a violation aborts with a clear
// message AND emits a structured `contract_violation` event on the execution tape
// (`emberc --tape`), so an LLM that wrote the spec learns exactly how an
// implementation betrayed it. A `--release` build elides the checks at zero cost.
//
// The contract is the specification; the body must satisfy it. Here both do.


// Euclid's GCD. The contract specifies a *common divisor*: the result is positive
// and divides both inputs. (That is a real, checkable spec — not just a comment.)
fn gcd(a: int, b: int) -> int
    requires a > 0
    requires b > 0
    ensures result > 0
    ensures a % result == 0
    ensures b % result == 0
{
    var x = a
    var y = b
    loop {
        if y == 0 {
            return x
        }
        let t = x % y
        x = y
        y = t
    }
}


// Clamp x into [lo, hi]. Precondition: the range is valid. Postcondition: the
// result is within it — guaranteed for every path through the body.
fn clamp(x: int, lo: int, hi: int) -> int
    requires lo <= hi
    ensures result >= lo
    ensures result <= hi
{
    if x < lo {
        return lo
    }
    if x > hi {
        return hi
    }
    return x
}


fn main() -> int {
    let g = gcd(48, 36)          // 12 — satisfies every postcondition
    let c = clamp(99, 0, 10)     // 10 — clamped into range
    println("gcd(48, 36) = {g}")
    println("clamp(99, 0, 10) = {c}")
    return 0
}
