// lam.em — a helper module. `run` passes a lambda (defined HERE) that divides by a captured
// divisor to a HOF; when the divisor is 0 the lambda traps. Proves a Fault inside a lambda
// reports THIS module's path, not the entry file (OFI-111a lambda case).
fn _apply(f: fn(int) -> int, x: int) -> int {
    return f(x)
}
fn run(x: int, d: int) -> int {
    return _apply(|n| n / d, x)
}
