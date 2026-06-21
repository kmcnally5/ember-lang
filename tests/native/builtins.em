// Native backend (M5) differential test: numeric conversions + native builtins.
// Covers to_float/to_int, width casts (u8/i32/...), libm math (sqrt/pow/abs/floor/
// ceil/round), the len() free function, wrapping arithmetic, and a passing assert.
// clock() is exercised for its sign only (its value is nondeterministic, so it is
// never printed) — every printed line must match the VM bit-for-bit.

fn main() -> int {
    // Conversions.
    let f = to_float(7)             // 7.0
    let n = to_int(3.9)             // 3 (truncates)
    let small = u8(300 - 45)        // 255 (in range)
    let wide = i32(-1000)           // -1000
    println("conv {f} {n} {small} {wide}")

    // libm math, all via the native dispatcher.
    println("sqrt {sqrt(144.0)}")           // 12
    println("pow {pow(2.0, 10.0)}")         // 1024
    println("abs {abs(0.0 - 5.5)}")         // 5.5
    println("floor {floor(3.7)} ceil {ceil(3.2)} round {round(2.5)}")

    // len() over an array, and wrapping arithmetic (modulo 2^width, no trap).
    let xs = [10, 20, 30]
    let w = wrapping_add(u8(250), u8(10))   // 4 (wraps at 256)
    println("len {len(xs)} wrap {w}")

    // clock() returns monotonic seconds — only its sign is deterministic.
    let t = clock()
    if t > 0.0 { println("clock ok") }

    // A passing assert is silent (it only speaks on failure).
    assert(int(small) == 255, "u8 saturation")

    return len(xs) + n + int(wide) + 1255   // 3 + 3 + (-1000) + 1255 = 261
}
