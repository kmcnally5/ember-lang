// divmod.em — a helper module whose divide traps on a zero divisor, to prove a Fault reports
// THIS module's path (not the entry file) for a trap that surfaces here (OFI-111a per-fn source).
fn divide(a: int, b: int) -> int {
    return a / b
}
