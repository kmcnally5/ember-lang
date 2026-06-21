// f32.em — 32-bit floats. Stored as double but rounded to 32-bit after each op;
// a literal becomes f32 from context, and f32<->f64 convert with type-name calls.
fn area(r: f32) -> f32 {
    return r * r * 3.14            // literal 3.14 adopts f32
}
fn main() -> int {
    let r: f32 = 2.0
    let a = area(r)               // ~12.56 (f32)
    println("{a}")
    let wide = f64(a)             // f32 -> f64
    println("{wide * 2.0}")       // ~25.12 (f64)
    let narrow = f32(100.5)       // f64 literal -> f32 via conversion
    println("{narrow}")
    return 0
}
