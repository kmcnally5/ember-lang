// error_generic_arity.em — wrong number of type arguments.
struct Box<T> { value: T }
fn main() -> int {
    let b = Box<int, int> { value: 1 }
    return 0
}
