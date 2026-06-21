// refcount_temp_arg.em — a fresh refcounted temporary passed straight into a
// borrowing call is reclaimed by the callee, not leaked, while an aliased
// argument survives the call. A refcounted parameter carries a reference the
// callee releases on return; the call site increfs an aliased argument to balance
// that release and adopts a temporary outright. The final read of `b` proves the
// aliased value is still live (no use-after-free); the "x" temporary handed to
// the first call is freed by that callee rather than leaked.
fn tag(s: string) -> string {
    return s + "!"
}

fn main() -> string {
    let a = tag("x")        // temporary "x": the callee owns and frees it
    let b = "y"
    let c = tag(b)          // aliased local b: must survive the callee's release
    return a + c + b        // "x!" + "y!" + "y" => x!y!y
}
