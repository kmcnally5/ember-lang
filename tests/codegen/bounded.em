// bounded_generic.em — a bounded generic function. `max<T: Ord>` calls the bound
// method `compare` through a witness (the dictionary of Version's methods for
// Ord), passed as a hidden argument. Exercises both branches of `max`.
interface Ord {
    fn compare(self, other: Self) -> int
}
struct Version implements Ord {
    n: int
    fn compare(self, other: Version) -> int {
        return self.n - other.n
    }
}
fn max<T: Ord>(move a: T, move b: T) -> T {
    if a.compare(b) >= 0 {
        return a
    }
    return b
}
fn main() -> int {
    let lo1 = Version { n: 3 }
    let hi1 = Version { n: 8 }
    let lo2 = Version { n: 3 }
    let hi2 = Version { n: 8 }
    return max(lo1, hi1).n + max(hi2, lo2).n   // 8 + 8 = 16 (max consumes its args)
}
