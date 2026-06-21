// ffi_null_handle.em — regression for the NULL-FILE* crash (REVIEW_FINDINGS M6). `fopen` of a
// missing path returns a null Ptr; passing it to fread/fwrite/fclose must NOT dereference NULL
// (that segfaulted, exit 139). The wrappers now degrade gracefully: fread/fwrite report 0 bytes
// and fclose returns EOF (-1), so an Ember program can detect and handle the failure.
extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fread(mut buf: [u8], n: i64, f: Ptr) -> i64
    fn fwrite(buf: [u8], n: i64, f: Ptr) -> i64
    fn fclose(move f: Ptr) -> i64
}


fn main() -> int {
    let f = fopen("/no/such/file/ember-regression", "r")
    var buf: [u8] = [0, 0, 0, 0]
    let nr = fread(buf, 4, f)        // 0 — no read, no crash
    let nw = fwrite(buf, 4, f)       // 0 — no write, no crash
    let rc = fclose(f)               // -1 (EOF) — no double-free crash
    println("nr={nr} nw={nw} rc={rc}")
    // nr=0 nw=0 rc=-1
    return nr + nw - rc              // 0 + 0 - (-1) = 1
}
