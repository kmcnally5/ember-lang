// OFI-098: `_` is the write-only discard, never a usable name — a function, struct, or enum named
// `_` is a compile error (each one).
fn _() -> int { return 7 }
struct _ { x: int }
enum _ { A B }
fn main() {}
