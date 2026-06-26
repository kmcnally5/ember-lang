// OFI-110(c)/111(c): a u64 dividend through a divide-by-zero Fault renders its operand UNSIGNED
// (its true value), not the negative two's-complement i64 view — same as the overflow path.
fn main() {
    let a: u64 = 18000000000000000000
    let b: u64 = 0
    let c = a / b            // traps at runtime: division by zero
    println("{c}")
}
