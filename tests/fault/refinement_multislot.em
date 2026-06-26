// refinement_multislot.em (fault) — OFI-150 soundness: a refined construction positioned AFTER a
// multi-slot value-struct argument in the same call MUST still trap on an out-of-range value.
type Pct = int where 0 <= self && self <= 100
struct Point { x: int  y: int }

fn take(p: Point, v: Pct) -> int {
    return p.x
}

fn main() -> int {
    let p = Point { x: 1, y: 2 }
    return take(p, Pct(150))
}
