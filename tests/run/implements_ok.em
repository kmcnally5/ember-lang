// implements_ok.em — a struct that satisfies an interface (Self resolves to the
// struct). Conformance is checked, methods run: compare(5,4) = 1.
interface Ord {
    fn compare(self, other: Self) -> int
}
struct Version implements Ord {
    number: int
    fn compare(self, other: Version) -> int {
        return self.number - other.number
    }
}
fn main() -> int {
    let a = Version { number: 5 }
    let b = Version { number: 4 }
    return a.compare(b)
}
