// Native backend (M2) differential test: array drop discipline under stress. A fresh
// array is built, grown, indexed, and dropped each iteration (50k times). A leak grows
// unbounded; a double-free crashes the recycle pool. The scalar result + clean exit
// confirm each array is freed exactly once.

fn main() -> int {
    var total = 0
    for i in 0..50000 {
        var a = [i, i + 1, i + 2]
        a.append(i + 3)
        total = total + a[3] - a[0]
    }
    return total
}
