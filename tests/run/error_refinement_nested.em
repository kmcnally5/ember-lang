// error_refinement_nested.em — OFI-150 stack-discipline regression: a VIOLATING refined
// construction in a non-trivial position (here the 2nd argument, so a temporary `100` is live
// on the stack below it) must TRAP. Before the fix the predicate read the sibling temporary's
// slot, found `100 > 0` true, and silently passed — letting a `-5` through a `self > 0` refinement.
type Pos = int where self > 0


fn id(a: int, b: Pos) -> int { return a + int(b) }


fn main() -> int {
    println(id(100, Pos(-5)))
    return 0
}
