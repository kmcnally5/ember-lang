// OFI-049 regression: an opaque FFI handle (Ptr) is a MOVE-ONLY resource. A closing call declared
// `move f: Ptr` consumes the handle, so closing it twice — use-after-move — is a COMPILE error
// rather than a runtime double-free. (Before the fix this compiled and double-closed the FILE*.)
extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fclose(move f: Ptr) -> i64
}

fn main() -> int {
    let f = fopen("/tmp/ember_dbl.txt", "w")
    let a = fclose(f)
    let b = fclose(f)        // f was already moved out by the first fclose
    return 0
}
