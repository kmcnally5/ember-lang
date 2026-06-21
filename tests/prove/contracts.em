// contracts.em — verification loop (§5j) brick 4: static contract proving over linear integer
// arithmetic. The prover substitutes `result` with a single-return body's expression and discharges
// `requires => ensures` by Fourier–Motzkin (sound: rational-infeasible => integer-infeasible). It
// proves the valid in-fragment postconditions and SOUNDLY declines the rest (deferring to --check),
// never claiming a false contract holds.
fn add_nonneg(a: int, b: int) -> int
    requires a >= 0
    requires b >= 0
    ensures result >= 0
{
    return a + b              // PROVED
}


fn scale(x: int) -> int
    requires x >= 0
    ensures result >= x
{
    return x * 2              // PROVED: x >= 0 => 2x >= x
}


fn diff_nonneg(a: int, b: int) -> int
    requires a >= b
    ensures result >= 0
{
    return a - b              // PROVED: a >= b => a - b >= 0
}


fn shift(x: int, k: int) -> int
    ensures result >= x
{
    return x + k              // NOT proved: k may be negative — falls back to --check
}


fn main() -> int { return 0 }
