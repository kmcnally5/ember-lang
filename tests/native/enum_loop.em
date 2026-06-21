// Native backend (M2) differential test: boxed enums + match under refcount stress. A
// fresh enum is built, passed to a consuming match function, and dropped each iteration
// (100k times). A refcount imbalance would leak (unbounded) or double-free (crash); the
// scalar result and clean exit confirm balance. Enums are boxed (heap, refcounted) — the
// checker's move/drop flags align with that, so passing retains and the callee releases.

enum E {
    A(n: int)
    B
}


fn val(e: E) -> int {
    match e {
        case A(n) { return n }
        case B    { return 0 }
    }
    return -1
}


fn main() -> int {
    var total = 0
    for i in 0..100000 {
        let e = A(i)
        total = total + val(e)
    }
    return total
}
