// OFI-123(a): a `u64` literal may now be written across the FULL unsigned range (up to 2⁶⁴−1), not
// just to i64-max — the parser parses the magnitude as unsigned and the checker admits it only where
// the type is u64. The bits live in the int64 slot and render unsigned, so this exercises the two
// edges that previously needed arithmetic: i64-max+1 (= 2⁶³, the INT64_MIN bit pattern) and u64-max.
// Runs on BOTH the VM and the native binary; their stdout must match (the differential guard).

fn main() {
    // The two edges, by annotation.
    let a: u64 = 9223372036854775808       // i64-max + 1  (= 2^63)
    let b: u64 = 18446744073709551615      // u64-max      (= 2^64 - 1)
    println("a={a} b={b}")

    // The `u64` suffix form, with no annotation.
    let c = 9223372036854775808u64
    let d = 18446744073709551615u64
    println("c={c} d={d}")

    // Arithmetic that reaches the top of the range (the old workaround) still agrees with the literal.
    let half: u64 = 9223372036854775807    // i64-max
    let viaArith = half + half + 1u64      // 2^64 - 1 (no overflow — exactly u64-max)
    println("arith={viaArith} eq={viaArith == b}")

    // A literal just under the i64 boundary is unaffected.
    let e: u64 = 42
    println("e={e}")
}
