// OFI-049: a `Ptr` closed on only ONE branch leaks on the other. Must-consume is an AND-merge — the
// dual of the affine move analysis — so a handle is consumed only if consumed on EVERY reaching path.
extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fclose(move f: Ptr) -> i64
}
fn run(c: bool) -> int {
    let f = fopen("/tmp/ember_x", "w")
    if c {
        let _c = fclose(f)
    }                              // the else path leaves f open → leak
    return 0
}
fn main() -> int { return run(true) }
