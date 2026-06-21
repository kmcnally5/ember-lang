// Native backend (M1) differential test: integer arithmetic + a direct call.
// The harness runs this on the VM and as a compiled native binary and requires
// identical stdout — the guard that keeps AST→C in lockstep with the reference VM.

fn sq(n: int) -> int {
    return n * n
}


fn main() -> int {
    let a = 7
    let b = 3
    let c = a * a - b * (a + 1) + sq(b)
    return c / 2 + a % b
}
