// array_growth.em — arrays are mutable, growable, uniquely-owned values. Elements
// can be reassigned (a[i] = v), the array grows with append, shrinks with
// remove_last (which moves the element out), and reports its size with len() —
// all in place, through a `var` binding or a `mut`/`move` parameter. An array is
// borrowed by a plain parameter and moved out when returned.
fn sum(xs: [int]) -> int {                  // borrows the array (read-only)
    var total = 0
    var i = 0
    loop {
        if i == xs.len() { return total }
        total = total + xs[i]
        i = i + 1
    }
    return total
}

fn fill_squares(n: int) -> [int] {          // builds and returns a fresh array
    var out: [int] = []
    var k = 1
    loop {
        if k > n { return out }             // early return moves `out` to the caller
        out.append(k * k)                   // still owned here (OFI-010 fixed)
        k = k + 1
    }
    return out
}

fn main() -> int {
    var a = [10, 20, 30]
    a[1] = 200                              // element mutation
    a.append(40)                            // grow
    let last = a.remove_last()              // 40 (moved out); a is [10, 200, 30]
    let squares = fill_squares(5)           // [1, 4, 9, 16, 25]
    return sum(a) + last + a.len() + sum(squares)
    //     240    + 40   + 3       + 55  = 338
}
