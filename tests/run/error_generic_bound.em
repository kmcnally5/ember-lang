// error_generic_bound.em — a struct bound is now supported, so the error is a type
// argument that does NOT satisfy it: `Bare` implements neither Hash nor Eq.
struct Keyed<K: Hash + Eq> {
    k: K
}
struct Bare {
    n: int
}
fn main() -> int {
    let x: Keyed<Bare> = Keyed<Bare> { k: Bare { n: 1 } }
    return 0
}
