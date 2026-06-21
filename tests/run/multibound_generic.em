interface Named { fn name(self) -> string }
interface Aged  { fn age(self) -> int }

struct Person implements Named, Aged {
    n: string
    a: int
    fn name(self) -> string { return self.n }
    fn age(self) -> int { return self.a }
}

// One type parameter with TWO bounds — calls a method from each.
fn describe<T: Named + Aged>(x: T) -> int {
    println(x.name())
    return x.age()
}

// Two type params, each bounded — exercises witness ordering.
fn pair_age<A: Aged, B: Aged>(p: A, q: B) -> int {
    return p.age() + q.age()
}

fn main() -> int {
    let p = Person { n: "Ada", a: 36 }
    let q = Person { n: "Bob", a: 4 }
    return describe(p) + pair_age(p, q)   // 36 + (36+4) = 76
}
