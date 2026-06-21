// array_struct_boxed_field.em — value-types Stage 3a.2: an array of a struct that has a
// REFCOUNTED boxed field (a string here) still stores its elements INLINE. Indexing makes
// a value copy that shares the boxed field via an incref; drop/overwrite releases it;
// append/remove_last transfer it. A double-free or use-after-free would corrupt or crash
// this; a missing release would leak (verified flat out-of-suite). The deterministic
// result confirms the refcount accounting on the boxed sub-fields is balanced.
// (A struct with a unique-owner field — a nested struct/array — falls back to boxed.)
struct Token {
    tag: int
    text: string
}


fn textlen(t: Token) -> int {       // borrow arg: reads the boxed field
    return t.text.len()
}


fn main() -> int {
    var ts = [Token { tag: 1, text: "hello" }]
    ts.append(Token { tag: 2, text: "worldly" })   // grows; "worldly" moves in

    let copy = ts[0]                  // value copy: shares "hello" via incref
    let viaField = ts[1].text.len()   // field read off a materialised copy (then dropped)
    let viaArg = textlen(ts[0])       // copy passed as a borrow, dropped after
    let last = ts.remove_last()       // "worldly" transferred out (Token{2,"worldly"})

    let from_copy = copy.tag + copy.text.len()       // 1 + 5
    let from_arr  = ts[0].text.len() + ts.len()      // 5 + 1  (ts[0] still "hello")
    let from_pop  = last.tag + last.text.len()       // 2 + 7
    return from_copy + from_arr + from_pop + viaField + viaArg   // 6 + 6 + 9 + 7 + 5 = 33
}
