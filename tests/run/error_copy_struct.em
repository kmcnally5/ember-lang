// error_copy_struct.em — a struct is a unique-owner move type, so it cannot satisfy a
// `T: Copy` bound. Binding one is rejected at the call: allowing it would reintroduce
// the aliasing double-free the move/Copy distinction exists to prevent (OFI-009).
struct P { v: int }

fn dup<T: Copy>(x: T) -> int {
    return 0
}

fn main() -> int {
    let p = P { v: 1 }
    return dup(p)
}
