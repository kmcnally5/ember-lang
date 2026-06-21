// OFI-049: a `Ptr`-returning call whose result is discarded (never bound to a name) leaks the handle
// — nothing can ever close it. Linearity is value-based, not only binding-based.
extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fclose(move f: Ptr) -> i64
}
fn main() -> int {
    fopen("/tmp/ember_x", "w")     // opened and immediately thrown away → leak
    return 0
}
