// array_struct_inline.em — an array of an all-scalar struct stores its elements INLINE
// (packed in the buffer, no per-element heap object), and the elements are VALUE TYPES
// (value-types campaign, MANIFESTO §5g). Indexing materialises a COPY, so an element can
// be bound out (`let a = arr[0]`) — which a boxed struct array forbids (it would alias).
// A mutated copy must NOT affect the array (the defining property of value semantics).
// Replaces the old error_array_struct_move test: that rejection is now a legal copy.
struct P {
    x: int
    y: int
}


fn main() -> int {
    var arr = [P { x: 1, y: 2 }, P { x: 3, y: 4 }]
    arr.append(P { x: 5, y: 6 })          // grows the inline buffer

    let first = arr[0]                    // a value copy (was rejected when boxed)
    var c = arr[1]                        // another copy, mutable
    c.x = 99                              // mutate the copy only
    let last = arr.remove_last()          // P{5,6} materialised out

    // arr is unchanged by the copy mutation (arr[1].x is still 3 despite c.x = 99).
    let from_copy = first.x + first.y + c.x            // 1 + 2 + 99
    let from_arr  = arr[0].x + arr[1].x + arr.len()    // 1 + 3 + 2
    let from_pop  = last.x + last.y                     // 5 + 6
    return from_copy + from_arr + from_pop             // 102 + 6 + 11 = 119
}
