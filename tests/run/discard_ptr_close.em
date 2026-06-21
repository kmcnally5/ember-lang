// discard_ptr_close.em — bare `let _ =` replaces the `let _name =` workaround for discarding the
// status of a move-consuming FFI close (OFI-095). `f` is consumed by fclose's `move` parameter, so
// must-consume is satisfied; the returned i64 status is discarded. Two closes in one scope prove
// the discard repeats.

extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fclose(move f: Ptr) -> i64
}

fn main() -> int {
    let a = fopen("/tmp/ofi095_close_a", "w")
    let _ = fclose(a)
    let b = fopen("/tmp/ofi095_close_b", "w")
    let _ = fclose(b)
    println("closed both")
    return 0
}
