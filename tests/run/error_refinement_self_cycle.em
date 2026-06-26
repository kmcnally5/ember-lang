// error_refinement_self_cycle.em — OFI-150: a `where` predicate that constructs its OWN type is a
// non-terminating refinement (checking it requires checking it). The checker must REJECT it with a
// clear diagnostic; earlier it slipped past the checker (which pre-marks the type checked) and made
// codegen recurse forever — a compiler stack-overflow / SIGSEGV.
type Loop = int where Loop(self) > 0


fn main() -> int {
    let x = Loop(5)
    println("{x}")
    return 0
}
