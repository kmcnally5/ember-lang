// OFI-103: repeat(s, n) must terminate for n <= 0 (returning ""), not loop forever. Before the fix
// the `if i == n` exit was never reached for a negative n, so repeat("y", -2) hung.
import "std/string" as str

fn main() -> int {
    let a = str.repeat("ab", 3)
    let b = str.repeat("x", 0)
    let c = str.repeat("y", -2)
    print("a=[{a}] b=[{b}] c=[{c}]\n")
    return 0
}
