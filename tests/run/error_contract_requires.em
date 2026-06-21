// error_contract_requires.em — a VIOLATED `requires` precondition aborts with a
// contract error before the body runs, rather than silently misbehaving (§5e).
fn clamp(x: int, lo: int, hi: int) -> int
    requires lo <= hi
{
    return x
}

fn main() -> int {
    return clamp(5, 10, 0)       // lo > hi — precondition fails
}
