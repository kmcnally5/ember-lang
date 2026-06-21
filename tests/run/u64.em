// u64.em — unsigned 64-bit integers. Values above i64-max (2^63) are the whole
// point: they must add, compare, divide, and print as *unsigned*, not wrap to a
// negative. The bits live in the same slot as i64, so the numeric kind drives the
// unsigned behaviour. Conversion from a signed int reinterprets the bit pattern.
fn main() -> int {
    let big: u64 = 9000000000000000000        // ~9.0e18, just under 2^63
    let sum = big + big                         // 1.8e19 — past i64-max, fits u64
    println("{sum}")                            // 18000000000000000000 (unsigned)
    if sum > big { println("gt") }              // unsigned ordering
    println("{sum / 3}")                        // unsigned divide: 6000000000000000000
    println("{sum % 7}")                        // unsigned remainder
    let five: u64 = u64(5)                      // int -> u64
    println("{five + 1}")                       // literal 1 adopts u64 -> 6
    return 0
}
