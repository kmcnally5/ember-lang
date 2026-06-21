// modlib/worker.em — a spawnable worker function, imported module-qualified by spawn_qualified.em
// to exercise `spawn worker.double_into(...)` (OFI-091: module-qualified spawn targets).
fn double_into(out: Channel<int>, n: int) { send(out, n * 2) }
