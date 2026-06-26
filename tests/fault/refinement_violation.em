// refinement_violation.em (fault) — OFI-150: constructing a refined newtype out of its domain traps
// as a structured `refinement_violation` Fault that names the type and the construction site.
type Percent = int where 0 <= self && self <= 100

fn main() -> int {
    let p: Percent = Percent(150)
    return 0
}
