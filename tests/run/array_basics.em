// array_basics.em — array literals, indexing, and len.
fn main() -> int {
    let a = [10, 20, 30]
    return a[0] + a[2] + len(a)   // 10 + 30 + 3 = 43
}
