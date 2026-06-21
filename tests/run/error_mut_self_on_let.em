// error_mut_self_on_let.em — OFI-048: a `mut self` method called on an immutable
// `let` receiver must be rejected. The receiver is not a mutable place, so the
// mutation either hits a throwaway value-copy (lost) or writes through a shared
// reference a `let` was meant to freeze — the same soundness hole the explicit
// `mut`-parameter place check closes (see error_mut_let_arg.em).
struct Counter {
    n: int

    fn bump(mut self) {
        self.n = self.n + 1
    }
}


fn main() -> int {
    let c = Counter { n: 0 }
    c.bump()                 // mut self on a `let` receiver — must NOT type-check
    return c.n
}
