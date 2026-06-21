// error_generic_field.em — type safety: a string can't fill a Box<int>'s field.
struct Box<T> { value: T }
fn main() -> int {
    let b = Box<int> { value: "no" }
    return 0
}
