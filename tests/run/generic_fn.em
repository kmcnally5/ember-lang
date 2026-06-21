// generic_fn.em — generic free functions, erased (one compiled body per fn),
// with type-argument inference from arguments and the expected return type. A
// generic that returns its argument *consumes* it, so the returned parameter is
// taken `move`: ownership of a `T` value cannot escape from a borrow (OFI-009).
fn identity<T>(move x: T) -> T { return x }
fn first<A, B>(move a: A, b: B) -> A { return a }
fn main() -> int {
    println(identity("hi"))         // T=string inferred from the argument
    return first(identity(7), 99)   // nested generic call; first<int,int> -> 7
}
