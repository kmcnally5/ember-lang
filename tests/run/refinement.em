// refinement.em — OFI-150: a `where` predicate makes a newtype a REFINEMENT type. The predicate
// (over `self`) is checked at construction; a read needs no recheck (the type is the proof). The
// predicate may call ordinary functions.
fn nonzero(n: int) -> bool { return n != 0 }
type Percent = int where 0 <= self && self <= 100
type Nat = int where self >= 0
type NonZero = int where nonzero(self)

fn main() -> int {
    let p: Percent = Percent(80)
    let n: Nat = Nat(0)
    let z: NonZero = NonZero(3)
    println("p={p} n={n} z={z}")
    return 0
}
