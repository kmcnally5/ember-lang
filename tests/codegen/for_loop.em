// for_loop.em — iterate an array; break and continue work.
fn main() -> int {
    let xs = [1, 2, 3, 4, 5]
    var sum = 0
    for x in xs {
        if x == 2 { continue }
        if x == 5 { break }
        sum = sum + x          // 1 + 3 + 4 = 8
    }
    return sum
}
