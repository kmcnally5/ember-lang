// stdlib_list_sort.em — the merge sort in std/list. Verifies exact order with
// duplicates, descending order, stability (observable: distinct strings of equal
// length keep input order), and that a larger generated array comes out fully
// ordered (guards the recursive merge against off-by-one/lost-element bugs).
import "std/list" as list
fn main() -> int {
    var pass = 0

    // exact ascending order, with duplicates
    let xs = [5, 3, 8, 3, 1, 9, 3, 7, 2, 8]
    let asc = list.sort(xs, |a, b| a < b)
    let want = [1, 2, 3, 3, 3, 5, 7, 8, 8, 9]
    var same = 1
    var i = 0
    loop {
        if i == asc.len() { break }
        if asc[i] != want[i] { same = 0 }
        i = i + 1
    }
    if same == 1 { pass = pass + 1 }                 // 1

    // descending
    let desc = list.sort(xs, |a, b| a > b)
    if desc[0] == 9 && desc[9] == 1 { pass = pass + 1 }   // 2

    // stability: length-2 strings keep their input order (bb, aa, dd, ee).
    let words = ["bb", "aa", "dd", "c", "ee"]
    let bylen = list.sort(words, |a, b| a.len() < b.len())
    if bylen[0] == "c" && bylen[1] == "bb" && bylen[2] == "aa" &&
       bylen[3] == "dd" && bylen[4] == "ee" { pass = pass + 1 }   // 3

    // a larger generated array (many duplicates) comes out fully ordered.
    var big: [int] = []
    var seed = 99
    i = 0
    loop {
        if i == 1000 { break }
        seed = (seed * 1103515245 + 12345) % 2147483648
        big.append(seed % 500)
        i = i + 1
    }
    let sorted = list.sort(big, |a, b| a < b)
    var ordered = 1
    i = 1
    loop {
        if i == sorted.len() { break }
        if sorted[i] < sorted[i - 1] { ordered = 0 }
        i = i + 1
    }
    if ordered == 1 && sorted.len() == 1000 { pass = pass + 1 }   // 4

    println("pass={pass}/4")
    return pass                                       // 4
}
