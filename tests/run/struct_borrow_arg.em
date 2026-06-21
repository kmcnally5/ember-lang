// struct_borrow_arg.em — a value-struct local passed BY BORROW (used again, so NOT moved) to a
// function must not be double-freed. A heap-boxed struct local exploded into a multi-slot param
// used the reclaiming OP_UNBOX_STRUCT, which freed the LIVE local; its scope-exit OP_DROP then
// double-freed it (a crash in free_list at exit). Now codegen emits OP_UNBOX_STRUCT_BORROW for a
// borrowed local — it keeps the shell and retains heap leaves. Regression for OFI-058.
// (Run under build/emberc-asan to confirm memory-safety; the golden locks the executed result.)
struct Pt {
    x: int
    y: int
    z: int
}






fn mk(n: int) -> Pt {
    return Pt { x: n, y: n * 2, z: n * 3 }
}






fn sum(p: Pt, k: int) -> int {
    return p.x + p.y + p.z + k
}






fn main() -> int {
    let base = mk(5)                     // a heap-boxed struct local (from a call result)
    var total = 0
    var i = 0
    loop {
        if i == 4 {
            break
        }
        total = total + sum(base, i)     // borrow: `base` is reused each iteration, never moved
        i = i + 1
    }
    return total
}
