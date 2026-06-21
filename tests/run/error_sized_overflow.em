// error_sized_overflow.em — sized-integer arithmetic traps at the operand width,
// like `int` does at 64 bits. 200 + 100 exceeds u8's range (0..255).
fn main() -> int {
    let a: u8 = 200
    let b: u8 = 100
    let c = a + b
    return i64(c)
}
