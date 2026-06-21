// error_void_method_value.em — OFI-014 regression. A void-returning method used in
// value position must be a compile error, not a silent garbage value / crash. Before
// the fix, a void method's result type was TY_ERROR (the error-suppression sentinel),
// so `x = c.bump()` was silently accepted and codegen emitted a garbage slot that the
// VM later dereferenced — a SIGSEGV for a heap-typed target (e.g. a Map). Now a void
// method yields TY_UNIT, exactly like a void free function, and is rejected here.
struct Counter {
    n: int
    fn bump(mut self) { self.n = self.n + 1 }
}
fn main() -> int {
    var c = Counter { n: 0 }
    var x = 0
    x = c.bump()         // bump returns nothing — this must not type-check
    return x
}
