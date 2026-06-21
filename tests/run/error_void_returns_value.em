// error_void_returns_value.em — a function with no declared return type is a
// unit function; returning a value from it is a compile error.
fn f() {
    return 5
}

fn main() {
    f()
}
