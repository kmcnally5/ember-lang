// generic_box.em — generic structs: each type parameter substitutes per instance.
// Box<int>.value is int; Pair<int,int>.first/second are int. 42+3+4 = 49.
struct Box<T> { value: T }
struct Pair<A, B> { first: A  second: B }
fn main() -> int {
    let b = Box<int> { value: 42 }
    let p = Pair<int, int> { first: 3, second: 4 }
    return b.value + p.first + p.second
}
