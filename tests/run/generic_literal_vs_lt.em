// generic_literal_vs_lt.em — OFI-002 regression. The parser must tell a generic
// struct literal `Name<T> { … }` apart from a less-than comparison `name < x` by
// lookahead alone, with NO turbofish. The decision is sound, not a heuristic: no
// expression begins with '{', so `> {` can't continue a comparison, and a type-
// argument list contains only type-legal tokens — any other token proves the '<'
// is a comparison. This program puts both readings side by side, including the
// shared-prefix and comma-spanning cases that stress the lookahead.
struct Pair<A, B> {
    first: A
    second: B
}
struct Box<T> {
    value: T
}


fn pick(cond: bool, b: Box<int>) -> int {
    if cond { return b.value }
    return 0
}


fn main() -> int {
    // Generic struct literals: the `<…> {` form, including a nested instantiation.
    let p = Pair<int, int> { first: 3, second: 4 }
    let nested = Box<Pair<int, int>> { value: Pair<int, int> { first: 10, second: 20 } }

    // Comparisons that share the '<' prefix — must parse as less/greater-than.
    let a = 1
    let b = 2
    var sum = 0
    if a < b { sum = sum + 1 }                 // '<' in a header: comparison
    if b > a { sum = sum + 1 }                 // '>' too
    if p.first < p.second { sum = sum + 1 }    // member operands, still comparison
    let lt = a < b                             // value-position comparison

    // A call whose first argument is a comparison and whose second is a generic
    // literal: the lookahead from the first '<' must scan across the comma and the
    // inner `Box<int>{…}` and still conclude "comparison" (it ends at the '}' /
    // the non-type tokens), not swallow the literal.
    let picked = pick(a < b, Box<int> { value: 9 })

    var total = p.first + p.second + nested.value.first + nested.value.second  // 37
    if lt { total = total + 100 }              // 137
    total = total + sum + picked               // 137 + 3 + 9 = 149
    return total
}
