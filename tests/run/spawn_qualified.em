// spawn_qualified.em — regression for OFI-091: `spawn` a MODULE-QUALIFIED function. The checker once
// rejected `spawn worker.double_into(...)` ("'spawn' requires a call to a named function") because it
// only accepted a bare-identifier callee; the fix resolves a qualified callee the same way a qualified
// direct call does, and both backends already read the cached resolved_fn. Serial-safe: the recv runs
// after the nursery joins, so it does not depend on the parallel scheduler.
import "modlib/worker" as worker
fn main() -> int {
    let ch: Channel<int> = channel(2)
    nursery {
        spawn worker.double_into(ch, 21)
    }
    match recv(ch) {
        case Some(v) { println("got {v}") }
        case None { println("none") }
    }
    return 0
}
