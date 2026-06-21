// Native backend (M3c) differential test: bounded generics (interface-witness dictionary
// passing). A bounded generic free function receives its type parameter's interface witness
// as a hidden leading argument (an enum record of the impl's method fn-indices); a method
// call on the erased type parameter reads the method's fn-index from that witness and
// dispatches through rt_call_indirect. The struct argument is boxed into the erased body and
// the struct result unboxed back — the value-struct<->boxed bridge.
interface Ord {
    fn compare(self, other: Self) -> int
}

struct Version implements Ord {
    number: int

    fn compare(self, other: Version) -> int {
        return self.number - other.number
    }
}

fn max<T: Ord>(move a: T, move b: T) -> T {
    if a.compare(b) >= 0 {
        return a
    }
    return b
}

fn min<T: Ord>(move a: T, move b: T) -> T {
    if a.compare(b) < 0 {
        return a
    }
    return b
}

fn main() -> int {
    let hi = max(Version { number: 3 }, Version { number: 7 })
    let lo = min(Version { number: 9 }, Version { number: 2 })
    println("hi {hi.number}")
    println("lo {lo.number}")
    return hi.number + lo.number
}
