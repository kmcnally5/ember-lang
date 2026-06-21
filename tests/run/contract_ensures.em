// contract_ensures.em — the full picture: a `requires` precondition and two `ensures`
// postconditions referring to `result` (the return value). The model can write the
// spec (the clauses) and the impl separately; the runtime checks the impl against it
// (MANIFESTO §5e). All clauses hold here, so clamp runs normally.
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
    return clamp(42, 0, 10)      // above hi → clamped to 10
}
