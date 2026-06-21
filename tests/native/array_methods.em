// Native backend (M5) differential test: array .remove_last() and .slice(lo, hi).
// remove_last pops + returns the last element (mutating the array in place); slice
// copies a range into a fresh OWNED array (heap elements retained). Exercised over a
// scalar [int] and a refcounted [string] so the drop discipline is covered both ways.

fn main() -> int {
    var xs = [1, 2, 3, 4, 5]
    let last = xs.remove_last()              // 5; xs is now [1,2,3,4]
    let mid = xs.slice(1, 3)                 // [2, 3] (a fresh owned copy)
    println("last = {last} len = {xs.len()}")
    println("mid = {mid[0]},{mid[1]} midlen = {mid.len()}")

    var words = ["alpha", "beta", "gamma"]
    let tail = words.remove_last()           // "gamma"
    let head = words.slice(0, 1)             // ["alpha"]
    println("tail = {tail}")
    println("head = {head[0]} headlen = {head.len()}")

    return last + xs.len() + mid[0] + mid[1] + mid.len()   // 5 + 4 + 2 + 3 + 2 = 16
}
