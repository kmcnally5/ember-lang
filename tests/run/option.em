// option.em — Option<T> as a generic enum: Some(x) infers T from the argument,
// None infers T from the annotation; match binds the payload.
enum Option<T> {
    Some(value: T)
    None
}
fn unwrap_or(o: Option<int>, fallback: int) -> int {
    match o {
        case Some(v) { return v }
        case None    { return fallback }
    }
    return fallback
}
fn main() -> int {
    let a = Some(5)
    let b: Option<int> = None
    return unwrap_or(a, 0) + unwrap_or(b, 100)
}
