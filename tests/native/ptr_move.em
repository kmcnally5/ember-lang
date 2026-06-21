// OFI-049 positive: borrowing calls leave a Ptr usable; only a `move` close consumes it; and a
// `var` handle revives on reassignment. Self-contained (temp file), deterministic output.
extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fwrite(buf: [u8], n: i64, f: Ptr) -> i64
    fn fclose(move f: Ptr) -> i64
}
fn main() -> int {
    var bytes: [u8] = []
    bytes.append(69u8)
    bytes.append(77u8)
    let p = "/tmp/ember_ptr_move.bin"
    var f = fopen(p, "w")
    let w1 = fwrite(bytes, 2, f)     // borrow f
    let w2 = fwrite(bytes, 2, f)     // borrow f again — still usable
    let c1 = fclose(f)               // move f (consumed)
    f = fopen(p, "w")                // var revives: f usable again
    let w3 = fwrite(bytes, 2, f)     // borrow the revived handle
    let c2 = fclose(f)               // move again
    println("w {w1} {w2} {w3} c {c1} {c2}")
    return 0
}
