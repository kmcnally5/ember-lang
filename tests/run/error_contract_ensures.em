// error_contract_ensures.em — an implementation that violates its own postcondition
// is caught at the return, not shipped (MANIFESTO §5e). `result` is the return value.
fn doubled_is_positive(x: int) -> int
    ensures result > 0
{
    return x * 2              // negative x makes the postcondition false
}

fn main() -> int {
    return doubled_is_positive(0 - 3)
}
