// OFI-147: a top-level constant whose value does not match its declared type is a compile error
// (was silently accepted — the annotation was inert at module scope).
let X: int = "hello"
fn main() {}
