// error_generic_use_after_move.em — ownership is now enforced INSIDE generic bodies
// (OFI-009). A type parameter is a move type, so aliasing a `T` value is a use-after-
// move — caught at compile time. Before this, a struct argument was double-owned and
// double-freed at runtime (a SIGTRAP), the exact memory-unsafety the checker exists
// to prevent. This is the regression guard.
struct Box { v: int }

fn leak<T>(move t: T) -> int {
    let a = t          // moves t
    let b = t          // use-after-move: t no longer owns a value
    return 0
}

fn main() -> int {
    let p = Box { v: 1 }
    return leak(p)
}
