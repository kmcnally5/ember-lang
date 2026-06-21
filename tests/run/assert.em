// assert.em — verification loop (§5j) brick 1: in-language `assert(cond [, "msg"])`. It lowers to
// the contract-check machinery, so a violation is a structured tape event (contract_violation),
// not a bare crash, and is release-elided like a contract. Here every assertion holds.
fn checked_div(a: int, b: int) -> int {
    assert(b != 0, "divisor must be nonzero")
    return a / b
}
fn main() -> int {
    let x = checked_div(10, 2)        // 5
    assert(x == 5)                    // auto message form
    assert(x > 0, "x should be positive")
    return x
}
