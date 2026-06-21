// stdlib_list.em — the generic std/list toolkit (map/filter/reduce/sort) driven by
// closures, imported and called qualified. Exercises type-argument inference from
// array AND function arguments (OFI-015): int and string element types, a capturing
// lambda passed to a generic HOF, a named function as a reducer, a string reducer,
// and comparator lambdas (including ordering strings by length).
import "std/list" as list
fn add(a: int, b: int) -> int { return a + b }
fn main() -> int {
    let xs = [5, 2, 8, 1, 9, 3]
    let threshold = 3
    let big = list.filter(xs, |x| x > threshold)     // [5, 8, 9]  (capturing lambda)
    let doubled = list.map(big, |x| x * 2)           // [10, 16, 18]
    let total = list.reduce(doubled, 0, add)         // 44  (named fn as the reducer)

    let words = ["bb", "a", "ccc"]
    let lens = list.map(words, |w| w.len())          // [2, 1, 3]   ([string] -> [int])
    let lensum = list.reduce(lens, 0, |a, x| a + x)  // 6
    let joined = list.reduce(words, "", |acc, w| acc + w)   // "bbaccc"  (string accumulator)

    let asc = list.sort(xs, |a, b| a < b)            // [1, 2, 3, 5, 8, 9]
    let desc = list.sort(xs, |a, b| a > b)           // [9, 8, 5, 3, 2, 1]
    let bylen = list.sort(words, |a, b| a.len() < b.len())  // ["a", "bb", "ccc"]

    println("total={total}")                         // 44
    println("joined={joined}")                       // bbaccc
    println("lo={asc[0]} hi={asc[5]} top={desc[0]}") // lo=1 hi=9 top=9
    println("shortest={bylen[0]}")                   // a
    // 44 + 6 + 6 + 1 + 9 + 9 + 1 = 76
    return total + lensum + joined.len() + asc[0] + asc[5] + desc[0] + bylen[0].len()
}
