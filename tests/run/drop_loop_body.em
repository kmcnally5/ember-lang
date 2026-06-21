// drop_loop_body.em — a value built inside a `for` body or a `match` arm is
// reclaimed at the end of each iteration / arm, not leaked. Each `for` iteration
// allocates a fresh struct and string; the `match` arm declares a local string.
// Correct totals prove nothing is freed too early, and the per-iteration release
// keeps a long-running loop from growing without bound.
fn from_arm(t: Option<int>) -> int {     // Option comes from the prelude
    match t {
        case Some(n) { let label = "k"  return n + 1 }   // a binding inside the arm
        case None    { return 0 }
    }
    return 0
}

struct P { x: int }

fn make(n: int) -> P {
    return P { x: n * n }
}

fn main() -> int {
    var sum = 0
    for i in [1, 2, 3, 4] {
        let p = make(i)        // struct, freed each iteration
        let s = "v"            // string, freed each iteration
        sum = sum + p.x
    }
    return sum + from_arm(Some(9))   // 30 + 10 = 40
}
