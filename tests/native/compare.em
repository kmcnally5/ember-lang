// Native backend (M1) differential test: comparisons, &&/||/!, negative ranges.

fn check(x: int) -> int {
    if x > 0 && x < 100 {
        return 1
    }
    return 0
}


fn main() -> int {
    var n = 0
    for i in -2..5 {
        if check(i * 10) == 1 || i == -2 {
            n = n + 1
        }
        if !(i == 0) {
            n = n + 1
        }
    }
    return n
}
