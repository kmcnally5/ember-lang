// unit_method_ensures.em — a `mut self` method that returns unit (no value) may carry
// an `ensures` constraining its own state after the call (MANIFESTO §5e). This was
// blocked until OFI-026 was fixed: the root cause was an uninitialised `closure_call`
// field on call nodes (the arena does not zero memory), which only surfaced once a
// unit method's `ensures` shifted the parse-time allocation pattern — corrupting
// call resolution in an unrelated module. `new_expr` now zero-initialises every node.
// Here the postcondition holds, so reset runs and the state invariant is enforced.
struct Counter {
    n: int


    fn reset(mut self)
        ensures self.n == 0
    {
        self.n = 0
    }


    fn bump(mut self, by: int)
        requires by > 0
        ensures self.n > 0
    {
        self.n = self.n + by
    }
}


fn main() -> int {
    var c = Counter { n: 9 }
    c.reset()          // ensures self.n == 0 holds
    c.bump(5)          // requires by > 0; ensures self.n > 0 holds
    return c.n         // 5
}
