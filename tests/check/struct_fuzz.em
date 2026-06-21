// struct_fuzz.em — verification loop (§5j): `--check` fuzzes all-scalar STRUCT parameters by
// generating their leaf fields (a multi-slot struct param arrives as its field slots, so the
// fuzzer flattens it to leaves, then regroups them as `{...}` in the counterexample). Mixed
// scalar + struct parameters and `requires`-gating both work; counterexamples are still shrunk.
struct Pt {
    x: int
    y: int
}


fn sum_pt(p: Pt) -> int
    ensures result >= 0
{
    return p.x + p.y        // BUG: negative when x + y < 0 — minimal repro {-1, 0}
}


fn mixed(k: int, p: Pt) -> int
    requires k > 0
    ensures result >= k
{
    return k + p.x          // BUG: a negative p.x drops the result below k
}


fn main() -> int { return 0 }
