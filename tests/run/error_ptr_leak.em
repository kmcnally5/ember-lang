// OFI-049 (leak half): a `Ptr` opened but never closed leaks. A Ptr is LINEAR — it must be consumed
// (closed or returned) on every path — so an un-closed handle is now a COMPILE error, not a silent
// leak at run time. The fix that closes OFI-049's open half.
extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fclose(move f: Ptr) -> i64
}
fn main() -> int {
    let f = fopen("/tmp/ember_x", "w")
    return 0                       // f is never closed → leak
}
