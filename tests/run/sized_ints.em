// sized_ints.em — explicit-width integers (i8/i16/i32/i64, u8/u16/u32). A literal
// takes its width from context or a suffix; arithmetic is checked at the operand
// width (overflow traps); conversions are written as type-name calls. They are a
// semantic distinction here (the runtime value model is width-erased), so a value
// widened back to i64 still reads correctly.
fn wrap_byte(n: i32) -> u8 {
    return u8(n % 256)               // n % 256 always fits a byte
}

fn main() -> int {
    let a: u8 = 200
    let b: u8 = 55
    let sum = a + b                  // 255 — fits u8
    let big: i32 = 70000             // too big for i16, fine for i32
    let scaled = big * 2             // 140000 — literal 2 adopts i32
    let tagged = 1000u16             // suffix literal
    let next = tagged + 24           // 1024 — literal 24 adopts u16
    let byte = wrap_byte(513)        // 513 % 256 = 1
    return i64(sum) + i64(scaled) + i64(next) + i64(byte)
    //     255      + 140000      + 1024      + 1  = 141280
}
