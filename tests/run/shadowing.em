// shadowing.em — an inner block-local shadows the parameter; the outer is intact
// after the block. f(99): inner returns the shadow 5.
fn f(x: int) -> int {
    if true {
        let x = 5
        return x
    }
    return x
}
fn main() -> int {
    return f(99)
}
