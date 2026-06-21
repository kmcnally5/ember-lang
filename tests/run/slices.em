// slices.em — zero-copy array slices (slices §). `arr[lo..hi]` is a borrowed Slice<T> view:
// read-only, non-escaping, and it freezes its source while alive. `arr.slice(lo,hi)` is the
// copying companion that returns an OWNED [T] you can keep or return.


// A slice parameter accepts any window of any array, with no copy.
fn sum(xs: Slice<int>) -> int {
    var t = 0
    for x in xs {
        t = t + x
    }
    return t
}


// The copying companion lets a function hand back an owned sub-array.
fn first_n(a: [int], n: int) -> [int] {
    return a.slice(0, n)
}


fn main() -> int {
    let data = [10, 20, 30, 40, 50]

    let win = data[1..4]                       // a view of [20, 30, 40]
    println("len={win.len()} first={win[0]} last={win[2]} sum={sum(win)}")  // 3 20 40 90

    println("whole={sum(data[0..data.len()])}")        // 150 — a full-array view, no copy

    let mid = win[1..2]                        // slice of a slice → [30]
    println("mid={mid[0]} midlen={mid.len()}")          // 30 1

    let head = first_n(data, 3)                // an OWNED copy [10, 20, 30]
    println("head.len={head.len()} head1={head[1]}")    // 3 20

    return sum(win) + head.len()               // 90 + 3 = 93
}
