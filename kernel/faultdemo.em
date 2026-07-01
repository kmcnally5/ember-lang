// kernel/faultdemo.em — the fault-vector regression (kernel milestone 3;
// docs/design/kernel-freestanding.md). Deliberately triggers a synchronous CPU exception (a BRK, via
// the `cpu_break` direct extern) so the smoke test can confirm the vector table catches it and prints
// a kernel panic, instead of the process hanging silently. NOT the main demo — booted separately by
// tests/run-kernel.sh, which greps the panic banner.
extern "c" {
    fn cpu_break()
}


fn main() -> int {
    println("faultdemo: about to trigger a CPU exception...")
    cpu_break()
    // Unreachable: the BRK traps into the vector table, which prints a panic and halts.
    return 0
}
