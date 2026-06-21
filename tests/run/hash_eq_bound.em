// hash_eq_bound.em — the prelude's Hash + Eq as a multi-bound on a generic function,
// satisfied BOTH by built-in keys (int, string — native witnesses) and by a user struct
// that `implements Hash, Eq`. Each `probe` pair isolates the eq-branch (a big marker),
// so the result is independent of the impl-defined hash values.
struct Coord implements Hash, Eq {
    x: int
    y: int
    fn hash(self) -> int { return self.x * 31 + self.y }
    fn eq(self, other: Coord) -> bool { return self.x == other.x && self.y == other.y }
}


fn probe<K: Hash + Eq>(a: K, b: K) -> int {
    var n = a.hash()
    if a.eq(b) { n = n + 1000000000 }
    return n
}


fn main() -> int {
    let i = probe(5, 5) - probe(5, 6)             // int keys      -> 1e9
    let s = probe("a", "a") - probe("a", "b")     // string keys   -> 1e9
    let p = Coord { x: 1, y: 2 }
    let u = probe(p, Coord { x: 1, y: 2 }) - probe(p, Coord { x: 9, y: 9 })  // struct -> 1e9
    return i + s + u                              // 3000000000
}
