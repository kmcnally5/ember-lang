// OFI-100: the checker's `unreachable` flag must not bleed across function boundaries. `leaky()` is
// declared AFTER `first()`, whose body ends in a diverging `return` (which raises `unreachable`).
// Before the fix that stale flag skipped the linear-`Ptr` leak scan for `leaky`, so its un-closed
// handle compiled CLEAN; the open-but-not-closed error must fire regardless of declaration order.
extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fclose(move f: Ptr) -> i64
}
fn first() -> int {
    return 0
}
fn leaky() -> int {
    let f = fopen("/tmp/ember_x", "w")
    return 0
}
fn main() -> int {
    return first() + leaky()
}
