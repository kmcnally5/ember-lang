// error_discard_ptr_leak.em — discarding a linear Ptr via `_` is NOT an escape hatch around
// must-consume (OFI-049 stays sound under OFI-095's discard wildcard). A Ptr opened and then
// discarded has no destructor to run, so it still fails the opened-but-not-closed check.

extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fclose(move f: Ptr) -> i64
}

fn main() -> int {
    let _ = fopen("/tmp/ofi095_leak_test", "w")
    return 0
}
