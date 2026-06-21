// error_u64_overflow.em — u64 arithmetic traps when it would exceed 2^64, the
// same defined-overflow guarantee the signed widths have.
fn main() -> int {
    let a: u64 = 9000000000000000000
    let b = a + a + a                  // ~2.7e19 > 2^64 (1.84e19) -> trap
    println("{b}")
    return 0
}
