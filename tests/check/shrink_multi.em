// shrink_multi.em — verification loop (§5j): `--check` minimises (shrinks) a multi-argument
// counterexample toward the simplest failing input (deterministically, no RNG), so the agent
// gets a minimal repro. `diff_nonneg(a,b)` claims a non-negative result but fails when a < b;
// the smallest such input is (0, 1).
fn diff_nonneg(a: int, b: int) -> int
    ensures result >= 0
{
    return a - b
}
fn main() -> int { return 0 }
