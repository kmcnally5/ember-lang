// error_spawn_extern.em — a foreign (extern "c") function has no bytecode slot, so it cannot be
// spawned as a task; the checker rejects it with a clear diagnostic (rather than the compiler
// aborting at codegen — found in code review).
extern "c" { fn sin(x: f64) -> f64 }
fn main() -> int {
    nursery {
        spawn sin(1.0)
    }
    return 0
}
