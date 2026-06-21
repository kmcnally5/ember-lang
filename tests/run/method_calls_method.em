// method_calls_method.em — a method calls another method on self.
// area = 7*7 = 49; describe = area + side = 56.
struct Square {
    side: int
    fn area(self) -> int {
        return self.side * self.side
    }
    fn describe(self) -> int {
        return self.area() + self.side
    }
}
fn main() -> int {
    let s = Square { side: 7 }
    return s.describe()
}
