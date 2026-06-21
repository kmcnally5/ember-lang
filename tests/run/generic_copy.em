// generic_copy.em — the `T: Copy` bound (MANIFESTO §5f). A copyable type parameter
// (scalar, string, enum, closure — everything except a struct/array) may be aliased
// and returned by value WITHOUT `move`, unlike the move-by-default `T`. So a generic
// over copyable types reads naturally.
fn id<T: Copy>(x: T) -> T {
    return x                  // returns a copy — no `move` needed
}

fn alias<T: Copy>(x: T) -> int {
    let a = x                 // aliasing a Copy value compiles — for a move `T` this
    let b = x                 // would be a use-after-move
    return 0
}

fn main() -> int {
    println(id("copy"))       // T = string
    return id(40) + alias(2)  // 40 + 0 = 40
}
