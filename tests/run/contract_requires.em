// contract_requires.em — a `requires` precondition (MANIFESTO §5e). The clause holds
// for these arguments, so the function runs its body normally.
fn clamp(x: int, lo: int, hi: int) -> int
    requires lo <= hi
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
    return clamp(15, 0, 10)      // within range above hi → 10
}
