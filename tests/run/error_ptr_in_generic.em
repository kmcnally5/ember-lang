// OFI-049: a `Ptr` cannot be a generic type argument. A generic body is type-checked ONCE with its
// parameter abstract (never re-checked at T = Ptr), so a handle flowing through erased generics would
// escape linearity checking. `Some(f)` would form Option<Ptr> — rejected at construction.
extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fclose(move f: Ptr) -> i64
}
fn main() -> int {
    let f = fopen("/tmp/ember_x", "w")
    let o = Some(f)                // would wrap a linear handle in Option<Ptr>
    return 0
}
