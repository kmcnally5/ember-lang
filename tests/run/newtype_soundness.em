// newtype_soundness.em — OFI-149 regression for three bugs the original tests missed because they
// only used `let` bindings, literal construction, and int bases:
//   (1) a newtype's SemType band overlapped is_slice_type (no upper bound on SLICE_BASE), so a
//       `var` of newtype type was wrongly rejected as "a slice binding cannot be reassigned", and
//       for/index/slice/.len() on a newtype SEGFAULTED the compiler via slice_elem out-of-bounds.
//   (2) a width-type base (`Small(200)`) failed because the literal arg never adopted the base
//       width (c->expected was not set in the ctor check).
//   (3) a string-base newtype constructed from an existing string VARIABLE double-freed it — the
//       ctor is codegen-passthrough, so the aliased source needed an INCREF (consume()).
type UserId = int
type Small  = u8
type Email  = string

fn wrap(s: string) -> Email {
    return Email(s)
}

fn main() -> int {
    // (1) a `var` newtype can be reassigned with a same-newtype value.
    var u = UserId(1)
    u = UserId(9)
    println("u={int(u)}")

    // (2) a width-base newtype constructed from a literal that fits the width.
    let s: Small = Small(200)
    println("small={int(s)}")

    // (3) a string-newtype built from an existing string variable, kept alongside it — both must
    // remain valid (no refcount underflow / double free). Build several so an underflow would bite.
    let src = "user@example.com"
    let a = Email(src)
    let b = Email(src)
    let c = wrap(src)
    println("src={src} a={a} b={b} c={c}")
    return 0
}
