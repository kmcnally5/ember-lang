// error_try_bad_return.em — `?` needs the enclosing function to return the kind.
enum Option<T> { Some(value: T)  None }
fn bad(o: Option<int>) -> int {
    let v = o?
    return v
}
fn main() -> int { return 0 }
