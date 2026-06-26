// error_newtype_arith.em — OFI-149: arithmetic on a newtype is rejected (unwrap to the base first).
// Comparison/equality DO pass through (a < b is fine); only +/-/*/ etc. require an explicit unwrap.
type Money = int
fn main() -> int {
    let a: Money = Money(100)
    let b: Money = Money(50)
    let c = a + b
    return int(c)
}
