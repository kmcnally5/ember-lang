// ffi_struct.em — FFI structs by value (3b.6, the C ABI). An all-scalar Ember struct passed to
// or returned from an `extern "c"` function crosses the boundary as its scalar leaves; the
// registry wrapper reassembles a concrete C struct and passes/returns it BY VALUE, so the system
// C compiler generates the platform's aggregate calling convention (the C ABI). The boundary is
// defined by the leaf-scalar sequence, so a 2-field Vec2 matches a C `struct { double x, y; }`.
// (sin/cos etc. — the scalar slice — share the same OP_CALL_C path; see ffi_libm.em.)
struct Vec2 {
    x: f64
    y: f64
}


extern "c" {
    fn cvec2_len(v: Vec2) -> f64           // struct arg, scalar return
    fn cvec2_dot(a: Vec2, b: Vec2) -> f64  // two struct args
    fn cvec2_add(a: Vec2, b: Vec2) -> Vec2 // struct args AND struct return
    fn cvec2_scale(v: Vec2, k: f64) -> Vec2
}


fn main() -> int {
    let a = Vec2 { x: 3.0, y: 4.0 }
    let b = Vec2 { x: 1.0, y: 2.0 }
    let len = cvec2_len(a)                  // 5.0
    let dot = cvec2_dot(a, b)               // 3*1 + 4*2 = 11.0
    let sum = cvec2_add(a, b)               // {4.0, 6.0}
    let scaled = cvec2_scale(a, 2.0)        // {6.0, 8.0}
    let total = len + dot + sum.x + sum.y + scaled.x + scaled.y  // 5+11+4+6+6+8 = 40
    return to_int(total)
}
