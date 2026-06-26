// OFI-147: a top-level constant's annotation is honoured — a literal ADOPTS the declared width, and
// the value is checked against the annotation (a mismatch is a separate error test).
let A: u8 = 200
let B: f32 = 1.5
let C: int = 42
fn main() -> int {
    println("{A} {B} {C}")
    return 0
}
