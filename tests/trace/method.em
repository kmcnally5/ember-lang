// method_self.em — a method reads self's field and an explicit arg. 10 + 15 = 25.
struct Counter {
    value: int
    fn bump(self, by: int) -> int {
        return self.value + by
    }
}
fn main() -> int {
    let c = Counter { value: 10 }
    return c.bump(15)
}
