// generic_string.em — the same generic struct instantiated at a different type.
struct Box<T> { value: T }
fn main() -> string {
    let b = Box<string> { value: "hi" }
    return b.value
}
