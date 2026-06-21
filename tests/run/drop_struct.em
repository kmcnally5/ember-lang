// drop_struct.em — deterministic-drop coverage: a struct binding that owns a
// (nested) struct is freed at scope exit, recursively. A value moved out is NOT
// dropped by the mover (the receiver owns it), and an early return still frees
// the in-scope struct it leaves behind. The program's result proves every path
// computed correctly; AddressSanitizer (run separately) proves no double-free.
struct Inner { v: int }
struct Outer { a: Inner  b: int }

fn make() -> Outer {
    return Outer { a: Inner { v: 9 }, b: 1 }
}

fn eat(move o: Outer) -> int {
    return o.a.v               // o was moved in; this frame owns + frees it
}

fn use_then_drop() -> int {
    let o = make()             // owns a nested struct
    return o.a.v + o.b         // o freed here, recursively (=> 10)
}

fn move_out() -> int {
    let o = make()
    return eat(o)              // o moved; must not be freed by this frame (=> 9)
}

fn early(x: int) -> int {
    let o = make()
    if x > 0 { return o.b }    // early return frees o (=> 1)
    return o.a.v               // => 9
}

fn main() -> int {
    return use_then_drop() + move_out() + early(1) + early(0)   // 10+9+1+9 = 29
}
