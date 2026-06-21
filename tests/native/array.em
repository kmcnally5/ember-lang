// Native backend (M2) differential test: arrays (heap, move types). Literal construction,
// element read/write, append (growth), len, for-iteration, and passing an array to a
// function by borrow. Scalar element arrays for this slice.

fn sum(xs: [int]) -> int {
    var total = 0
    for x in xs {
        total = total + x
    }
    return total
}


fn main() -> int {
    var a = [10, 20, 30]
    a[1] = 25
    a.append(40)
    let n = a.len()
    return sum(a) + n + a[0]
}
