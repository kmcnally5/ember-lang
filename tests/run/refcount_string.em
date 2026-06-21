// refcount_string.em — strings are shared and reference-counted. Aliasing a
// string (binding-to-binding, into a struct field, reading a field back out)
// bumps the count; each owner releases it at scope exit, and the heap string is
// freed only when the last owner goes. Every alias below reads the *same* live
// string right up to the final concatenation — if a refcount were dropped early
// the read would hit freed memory and the result would be wrong.
struct Box { s: string  n: int }

fn field_of(b: Box) -> string {
    return b.s                      // reads a struct's string field (an alias)
}

fn main() -> string {
    let a = "hi"
    let b = a                       // alias (refcount up)
    let c = b                       // alias (refcount up)
    let box = Box { s: a, n: 0 }    // a copied into a struct field (refcount up)
    let d = field_of(box)           // box.s read back into d (refcount up)
    return a + b + c + d            // => hihihihi
}
