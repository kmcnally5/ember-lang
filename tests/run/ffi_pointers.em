// ffi_pointers.em — pointer/buffer FFI (§5h pointers). Exercises all three pointer leaf kinds:
//   'p' const char*  — a borrowed `string` (here a literal temp, released after the call)
//   'b' buffer       — a borrowed packed `[u8]` array (read for fwrite, written for fread)
//   'P' opaque Ptr   — a FILE* handle that round-trips through Ember (fopen → … → fclose)
// Self-contained (writes to a temp path), so it needs no fixture and its output is deterministic.
extern "c" {
    fn strlen(s: string) -> i64
    fn strncmp(a: string, b: string, n: i64) -> i64
    fn fopen(path: string, mode: string) -> Ptr
    fn fwrite(buf: [u8], n: i64, f: Ptr) -> i64
    fn fread(mut buf: [u8], n: i64, f: Ptr) -> i64
    fn fclose(move f: Ptr) -> i64
}


fn main() -> int {
    // 'p': const char* from a borrowed string literal (an owning temp the caller releases).
    let n = strlen("hello, ember")               // 12
    let same = strncmp("ember", "ember", 5)       // 0 — equal in the first 5 bytes

    // 'b' + 'P': write a byte payload to a file, then read it back into a fresh buffer.
    var out: [u8] = []
    out.append(69u8)                              // 'E'
    out.append(77u8)                              // 'M'
    out.append(66u8)                              // 'B'

    let path = "/tmp/ember_ffi_pointers.bin"
    let wf = fopen(path, "w")
    let wrote = fwrite(out, out.len(), wf)        // 3
    let cw = fclose(wf)

    var inb: [u8] = []
    inb.append(0u8)
    inb.append(0u8)
    inb.append(0u8)
    let rf = fopen(path, "r")
    let got = fread(inb, 3, rf)                    // 3
    let cr = fclose(rf)

    let sum = inb[0] + inb[1] + inb[2]             // 69 + 77 + 66 = 212
    println("len={n} eq={same} wrote={wrote} got={got} sum={sum}")
    return i64(sum)                                // 212
}
