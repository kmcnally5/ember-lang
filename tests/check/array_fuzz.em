// array_fuzz.em — verification loop (§5j): `--check` fuzzes immutable-borrow ARRAY parameters of
// full-width scalars by generating a small random-length array; `requires` can constrain the
// length; counterexamples are shrunk by removing any droppable element (at any position) and
// then simplifying survivors, so the reported array is minimal — e.g. `total([-1])`.
fn total(xs: [int]) -> int
    ensures result >= 0
{
    var sum = 0
    for x in xs {
        sum = sum + x
    }
    return sum            // BUG: negative when an element is negative
}


fn first_ok(xs: [int]) -> int
    requires xs.len() > 0
    ensures result >= 0
{
    return xs[0]          // BUG: a negative first element
}


fn main() -> int { return 0 }
