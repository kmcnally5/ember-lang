// error_resource_noop_drop.em — OFI-122 R6: a `resource struct`'s `drop` MUST close (consume) every
// linear `Ptr` handle field on every path. A no-op drop leaks the handle, so it is a compile error.
extern "c" {
    fn fclose(move h: Ptr) -> i64
}
resource struct Bad {
    conn: Ptr
    fn drop(self) { }
}
fn main() -> int { return 0 }
