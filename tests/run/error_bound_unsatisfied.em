// error_bound_unsatisfied.em — int does not implement Ord, so it cannot be the
// type argument of a bounded generic (primitives don't implement interfaces yet).
interface Ord { fn compare(self, other: Self) -> int }
fn max<T: Ord>(move a: T, move b: T) -> T {
    if a.compare(b) >= 0 { return a }
    return b
}
fn main() -> int {
    return max(1, 2)
}
