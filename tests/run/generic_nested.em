// generic_nested.em — nested instantiation Box<Box<int>>; chained field access.
struct Box<T> { value: T }
fn main() -> int {
    let b = Box<Box<int>> { value: Box<int> { value: 7 } }
    return b.value.value
}
