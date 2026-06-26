// OFI-098: a module-scope `let _ = <literal>` is a DISCARD (checked, but binds no usable name),
// exactly like a function-local `_`. Other top-level constants are unaffected.
let _ = 42
let _ = "ignored"
let GREETING = "hi"
fn main() -> int {
    println(GREETING)
    return 0
}
