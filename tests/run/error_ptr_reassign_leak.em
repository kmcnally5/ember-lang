// OFI-049: reassigning a `var f: Ptr` that still holds an un-closed handle drops it on the floor (a
// Ptr has no destructor), leaking it. Close the current handle before overwriting the binding.
extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fclose(move f: Ptr) -> i64
}
fn main() -> int {
    var f = fopen("/tmp/ember_a", "w")
    f = fopen("/tmp/ember_b", "w")     // the first handle is lost here → leak
    let _c = fclose(f)
    return 0
}
