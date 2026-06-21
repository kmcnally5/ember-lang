// for_range.em — integer ranges and the fused for-loops. Covers exclusive bounds,
// expression bounds, empty/reversed ranges (no iterations), break/continue,
// nesting, and that the array form still iterates correctly alongside ranges.
fn main() -> int {
    var pass = 0

    // exclusive: 0..5 yields 0,1,2,3,4
    var s = 0
    for i in 0..5 { s = s + i }
    if s == 10 { pass = pass + 1 }                 // 1

    // expression bounds
    let lo = 2
    let hi = 8
    s = 0
    for i in lo..hi { s = s + i }                  // 2+3+4+5+6+7 = 27
    if s == 27 { pass = pass + 1 }                 // 2

    // empty and reversed ranges run zero times
    var count = 0
    for i in 5..5 { count = count + 1 }
    for i in 9..3 { count = count + 1 }
    if count == 0 { pass = pass + 1 }              // 3

    // break and continue
    s = 0
    for i in 0..1000 {
        if i % 2 == 0 { continue }
        if i == 7 { break }
        s = s + i                                  // 1 + 3 + 5 = 9
    }
    if s == 9 { pass = pass + 1 }                  // 4

    // nesting (range inside range)
    var grid = 0
    for r in 0..4 {
        for c in 0..3 { grid = grid + 1 }
    }
    if grid == 12 { pass = pass + 1 }              // 5

    // array form still works, and a range over an array's length indexes it
    let xs = [10, 20, 30, 40]
    var asum = 0
    for x in xs { asum = asum + x }
    var isum = 0
    for i in 0..xs.len() { isum = isum + xs[i] }
    if asum == 100 && isum == 100 { pass = pass + 1 }   // 6

    println("pass={pass}/6")
    return pass                                    // 6
}
