// refinement_nested.em — OFI-150 stack-discipline regression: a refined construction works as a
// NON-trivial sub-expression — a 2nd/middle function argument, a binary RHS, a later array
// element, a nested construction — where the constructed value sits ABOVE live temporaries on
// the VM stack. Earlier, the `self` binding read the wrong slot (a sibling temporary), so the
// `where` predicate was checked against the wrong value (silently passing). All must hold here.
type Pct = int where 0 <= self && self <= 100
type Nat = int where self >= 0


fn three(a: int, b: Pct, c: int) -> int { return a + int(b) + c }


fn g(n: Nat) -> int { return int(n) }


fn main() -> int {
    // refined ctor as the MIDDLE argument (temporaries pushed before AND after)
    println(three(100, Pct(20), 3))                      // 123
    // refined ctor as a binary RHS (the LHS is already on the stack)
    if Pct(10) < Pct(90) { println("lt-ok") }            // lt-ok
    // later array element (earlier elements are live temporaries)
    let arr = [Pct(1), Pct(2), Pct(3)]
    println(int(arr[0]) + int(arr[1]) + int(arr[2]))     // 6
    // nested construction
    println(g(Nat(int(Pct(99)))))                        // 99
    return 0
}
