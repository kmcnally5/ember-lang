// error_missing_return.em — definite-return analysis (OFI-029). A function with a return type
// must return a value on every path; falling off the end would otherwise yield a silent
// garbage value. Here the `if` has no `else` and no trailing `return`, so the false path falls
// off — a compile error. (An `if/else` where both arms return, an exhaustive `match` whose arms
// all return, and an infinite `loop` with no `break` are all accepted as guaranteed exits.)
struct Pt { x: int  y: int }
fn maybe(c: bool) -> Pt {
    if c {
        return Pt { x: 1, y: 2 }
    }
}
fn main() -> int {
    let p = maybe(false)
    return p.x
}
