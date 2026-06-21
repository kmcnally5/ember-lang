// generic_nested_struct.em — regression for OFI-006: a generic-typed field of a
// generic struct must substitute the inner type parameter (Inner<T> in Outer<T>
// becomes Inner<int> under Outer<int>), so this valid program type-checks.
struct Inner<T> { v: T }
struct Outer<T> { i: Inner<T> }
fn main() -> int {
    let o = Outer<int> { i: Inner<int> { v: 5 } }
    return o.i.v
}
