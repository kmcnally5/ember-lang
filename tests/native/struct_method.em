// Native backend (M2c) differential test: struct method calls — the receiver is
// threaded as self (arg 0). Covers a method with a struct argument (passed by borrow),
// a `mut self` method mutating fields through the shared boxed receiver, and methods on
// both a `let` and a `var` binding.

struct Vec {
    x: int
    y: int

    fn dot(self, o: Vec) -> int {
        return self.x * o.x + self.y * o.y
    }

    fn scale(mut self, k: int) {
        self.x = self.x * k
        self.y = self.y * k
    }

    fn sum(self) -> int {
        return self.x + self.y
    }
}


fn main() -> int {
    let a = Vec { x: 1, y: 2 }
    let b = Vec { x: 3, y: 4 }
    var c = Vec { x: 5, y: 6 }
    c.scale(10)
    return a.dot(b) + c.sum()
}
