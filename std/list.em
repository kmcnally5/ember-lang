// std/list.em — the generic functional toolkit over arrays, written in Ember on
// top of closures: map, filter, reduce, sort. Each takes a function value (a named
// function or a lambda, which may capture), and the element types are inferred
// from the arguments:
//     import "std/list" as list
//     let evens = list.filter(xs, |x| x % 2 == 0)
//     let lens  = list.map(words, |w| w.len())          // [string] -> [int]
//     let total = list.reduce(xs, 0, |acc, x| acc + x)
//     let asc   = list.sort(xs, |a, b| a < b)
fn map<T, U>(xs: [T], f: fn(T) -> U) -> [U] {
    var out: [U] = []
    var i = 0
    loop {
        if i == xs.len() { return out }
        out.append(f(xs[i]))
        i = i + 1
    }
    return out
}






fn filter<T>(xs: [T], keep: fn(T) -> bool) -> [T] {
    var out: [T] = []
    var i = 0
    loop {
        if i == xs.len() { return out }
        if keep(xs[i]) { out.append(xs[i]) }
        i = i + 1
    }
    return out
}






fn reduce<T, U>(xs: [T], init: U, f: fn(U, T) -> U) -> U {
    var acc = init
    var i = 0
    loop {
        if i == xs.len() { return acc }
        acc = f(acc, xs[i])
        i = i + 1
    }
    return acc
}






// sort returns a sorted copy of xs, ordered by `less` (a strict "comes before"
// predicate). `sort(xs, |a, b| a < b)` is ascending. A top-down merge sort —
// O(n log n) comparisons, and stable (on a tie the left run's element comes first,
// because the merge takes from the right only when it strictly precedes).
fn sort<T>(xs: [T], less: fn(T, T) -> bool) -> [T] {
    return _sort_range(xs, 0, xs.len(), less)
}






// _sort_range returns a freshly-built sorted copy of xs[lo, hi). It recurses on the
// two halves and merges them; the recursion bottoms out at a 0- or 1-element slice.
fn _sort_range<T>(xs: [T], lo: int, hi: int, less: fn(T, T) -> bool) -> [T] {
    let n = hi - lo
    if n <= 1 {
        var out: [T] = []
        if n == 1 { out.append(xs[lo]) }
        return out
    }
    let mid = lo + n / 2
    let left = _sort_range(xs, lo, mid, less)
    let right = _sort_range(xs, mid, hi, less)
    return _merge(left, right, less)
}






// _merge interleaves two already-sorted runs into one. Ties keep `a` (the left run)
// first — taking from `b` only when it strictly precedes — so the sort is stable.
fn _merge<T>(a: [T], b: [T], less: fn(T, T) -> bool) -> [T] {
    var out: [T] = []
    var i = 0
    var j = 0
    loop {
        if i == a.len() {
            loop {
                if j == b.len() { return out }
                out.append(b[j])
                j = j + 1
            }
        }
        if j == b.len() {
            loop {
                if i == a.len() { return out }
                out.append(a[i])
                i = i + 1
            }
        }
        if less(b[j], a[i]) {
            out.append(b[j])
            j = j + 1
        } else {
            out.append(a[i])
            i = i + 1
        }
    }
    return out
}
