// slices.em — native differential test (OFI-054): borrowed array slice VIEWS `arr[lo..hi]`
// (zero-copy; the checker freezes the source and forbids the view escaping). Covers binding a
// slice, passing it to a Slice<T> parameter, iterating it, indexing, .len(), a full-array view,
// and a slice of a slice. The companion owned-copy `.slice(lo, hi)` method is covered elsewhere.
fn sum(xs: Slice<int>) -> int {
    var total = 0
    for x in xs {
        total = total + x
    }
    return total
}

fn main() -> int {
    let data = [10, 20, 30, 40, 50]
    let win = data[1..4]                  // a view over [20, 30, 40]
    let whole = sum(data[0..data.len()])  // 150 — a full-array view, inline
    let mid = win[1..2]                   // slice of a slice: [30]
    println("len={win.len()} first={win[0]} sum={sum(win)}")
    println("whole={whole} mid={mid[0]} midlen={mid.len()}")
    return win.len() + win[0] + sum(win) + whole + mid[0]   // 3+20+90+150+30 = 293
}
