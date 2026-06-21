// contract_fuzz.em — verification loop (§5j) brick 2: `emberc --emit=check` is property-based
// contract checking. Each fuzzable function (free, non-generic, an `ensures`, all-scalar params)
// is run on generated inputs; an input that falsifies a postcondition is reported as a concrete,
// REPRODUCIBLE counterexample (fixed-seed generator), and a `requires` precondition gates the
// domain (out-of-domain inputs are rejected, not reported). This is the agent correctness loop:
// write a contract, get a falsifying input back.
fn abs_val(x: int) -> int
    ensures result >= 0
{
    return x          // BUG: should negate when x < 0 — the fuzzer finds a negative counterexample
}


fn safe_div(a: int, b: int) -> int
    requires b != 0
    ensures true      // the point here is that the fuzzer respects `requires` (never divides by 0)
{
    return a / b
}


fn square(x: int) -> int
    ensures result >= 0   // holds for all int (overflow traps, not a postcondition violation)
{
    return x * x
}


fn main() -> int { return 0 }
