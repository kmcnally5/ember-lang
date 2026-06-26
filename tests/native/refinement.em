// refinement.em — OFI-150 differential: a VALID refined construction erases to the base value on
// both backends (native skips the VM-only check, like all contracts), so stdout matches.
type Percent = int where 0 <= self && self <= 100

fn main() -> int {
    let p: Percent = Percent(42)
    println("p={p}")
    return 0
}
