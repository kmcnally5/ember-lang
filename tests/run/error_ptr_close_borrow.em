// OFI-049: a BORROWED `Ptr` cannot be closed or transferred — the caller still owns the handle, so
// closing it here would strand them with a stale pointer (a double-close / use-after-free). To take
// ownership, declare the parameter `move f: Ptr`.
extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fclose(move f: Ptr) -> i64
}
fn closes(f: Ptr) -> i64 {         // borrows f (no `move`)
    return fclose(f)               // … but tries to consume it → error
}
fn main() -> int { return 0 }
