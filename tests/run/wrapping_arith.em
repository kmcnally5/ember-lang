// wrapping_arith.em — wrapping (modulo 2^width) integer arithmetic (OFI-041). The default
// `+ - *` trap on overflow; `wrapping_add`/`wrapping_sub`/`wrapping_mul` wrap instead, which is
// what hashes/PRNGs/checksums need. Width-aware: each wraps at its operand's width.


// FNV-1a, in pure Ember — the motivating use case (was impossible without wrapping multiply).
fn fnv1a(s: string) -> u32 {
    var h: u32 = 2166136261u32                  // FNV offset basis
    let bytes = s.chars()
    var i = 0
    loop {
        if i == bytes.len() { break }
        let b = u32(char_code(bytes[i]))
        h = wrapping_mul(h ^ b, 16777619u32)    // xor the byte, then wrap-multiply by the prime
        i = i + 1
    }
    return h
}


fn main() -> int {
    // u8 wraps at 256:
    println("add_u8={wrapping_add(200u8, 100u8)}")     // 300 mod 256 = 44
    println("sub_u8={wrapping_sub(10u8, 20u8)}")       // -10 mod 256 = 246
    println("mul_u8={wrapping_mul(255u8, 255u8)}")     // 65025 mod 256 = 1

    // u16 wraps at 65536:
    println("mul_u16={wrapping_mul(1000u16, 1000u16)}") // 1000000 mod 65536 = 16960

    // i8 wraps with two's-complement sign:
    println("add_i8={wrapping_add(100i8, 100i8)}")     // 200 -> -56

    // FNV-1a (the showcase): "hello" hashes to its canonical 32-bit value.
    println("fnv_hello={fnv1a("hello")}")              // 1335831723
    return i64(fnv1a("hello"))                          // 1335831723
}
