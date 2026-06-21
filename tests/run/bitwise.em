// bitwise.em — bitwise and shift operators (`& | ^ ~ << >>`). Covers the operators,
// their C-style precedence, signed vs unsigned shift, and width-aware behaviour on the
// explicit-width integer family. A systems language must do bits; this is the proof.
fn main() -> int {
    var acc = 0

    // and / or / xor on i64.
    acc = acc + (12 & 10)        // 1100 & 1010 = 1000 = 8
    acc = acc + (12 | 10)        // 1100 | 1010 = 1110 = 14
    acc = acc + (12 ^ 10)        // 1100 ^ 1010 = 0110 = 6

    // shifts on i64.
    acc = acc + (1 << 8)         // 256
    acc = acc + (1024 >> 4)      // 64
    acc = acc + (~5)             // -6  (two's complement)
    acc = acc + (-16 >> 2)       // -4  (arithmetic right shift keeps the sign)

    // precedence (matches C): & binds tighter than |, and + binds tighter than <<.
    acc = acc + (1 | 2 & 2)      // 1 | (2 & 2) = 1 | 2 = 3
    acc = acc + (1 + 1 << 4)     // (1 + 1) << 4 = 32

    // explicit-width behaviour. `~` on a narrow unsigned masks to the width; a left
    // shift truncates (wraps) to the width; an unsigned right shift is logical.
    let zero: u8 = 0
    acc = acc + int(~zero)    // ~0 over 8 bits = 255

    let one: u8 = 1
    let hi = one << 7            // u8: 128 (still in range)
    acc = acc + int(hi)       // 128

    let big: u8 = 200
    let wrapped = big << 1       // 400 & 0xFF = 144 (wraps to width)
    acc = acc + int(wrapped)  // 144

    let mask: u8 = 255
    let lo = mask >> 1           // logical: 127
    acc = acc + int(lo)       // 127

    return acc                   // 8+14+6+256+64-6-4+3+32+255+128+144+127 = 1027
}
