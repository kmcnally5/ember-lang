// error_unbounded_method.em — an unbounded T is opaque: no methods may be called.
fn bad<T>(a: T, b: T) -> int {
    return a.compare(b)
}
fn main() -> int { return 0 }
