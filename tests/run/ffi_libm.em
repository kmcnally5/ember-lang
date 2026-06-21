// ffi_libm.em — the foreign function interface (MANIFESTO §5h). An `extern "c"` block declares
// C functions by their Ember-side signature; calls then look like any call and dispatch through
// the in-tree C-math registry (OP_CALL_C). First slice: scalar args/returns against libm. The
// declared signature is type-checked against the registry (arity + float/int kinds); a struct-
// by-value boundary (the C ABI) builds on this next.
extern "c" {
    fn sin(x: f64) -> f64
    fn cos(x: f64) -> f64
    fn atan2(y: f64, x: f64) -> f64
    fn log2(x: f64) -> f64
    fn hypot(a: f64, b: f64) -> f64
}


fn main() -> int {
    let s = sin(0.0)              // 0.0
    let c = cos(0.0)              // 1.0
    let quarter = atan2(1.0, 1.0) // pi/4 ≈ 0.785398
    let l = log2(8.0)            // 3.0
    let h = hypot(3.0, 4.0)      // 5.0
    let total = s + c + quarter + l + h          // ≈ 9.785398
    return to_int(total * 1000.0)                // 9785
}
