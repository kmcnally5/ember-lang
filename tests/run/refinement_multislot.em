// refinement_multislot.em — OFI-150: a refined construction nested AFTER a multi-slot value-struct
// arg in the same call still checks correctly (the check is stack-balanced via self-substitution,
// not slot-based — the earlier inline approach silently bypassed it here).
type Pct = int where 0 <= self && self <= 100
struct Point { x: int  y: int }

fn take(p: Point, v: Pct) -> int {
    return p.x + p.y + int(v)
}

fn main() -> int {
    let p = Point { x: 1, y: 2 }
    println("r={take(p, Pct(40))}")
    return 0
}
