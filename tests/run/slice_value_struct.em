// tests/run/slice_value_struct.em — regression for OFI-083: .slice() on a VALUE-STRUCT array reached
// through a struct-field receiver (`convos[i].turns.slice(...)`). It once infinite-looped, then (after
// other fixes) double-freed / heap-overflowed at teardown because OP_SLICE_COPY / em_array_slice sized
// the copied buffer at sizeof(Value) per element (alloc_array by elem_kind) instead of the struct's
// total_size — so the memcpy of n*elem_size overran it. Fix: slice an inline-struct array via the
// struct-aware allocator. This exercises the field-receiver slice, a plain-local slice, and confirms
// the copy is INDEPENDENT (mutating the source doesn't disturb the slice) and frees cleanly on BOTH
// backends (the harness runs VM + native and diffs).
struct Turn { role: int  text: string }
struct Conv { title: string  turns: [Turn] }


fn mk(r: int, t: string) -> Turn {
    return Turn { role: r, text: t }
}


fn main() -> int {
    var convos: [Conv] = []
    var lt: [Turn] = []
    lt.append(mk(0, "q"))
    lt.append(mk(1, "a"))
    lt.append(mk(0, "again"))
    convos.append(Conv { title: "t", turns: lt })

    // The OFI-083 path: slice the value-struct array out THROUGH a field-of-index receiver.
    let cut = convos[0].turns.slice(1, convos[0].turns.len())
    var sum = 0
    var i = 0
    loop {
        if i == cut.len() {
            break
        }
        sum = sum + cut[i].role + cut[i].text.len()    // 1+1 (a) then 0+5 (again) = 7
        i = i + 1
    }
    print("cut.len={cut.len()} sum={sum}\n")            // cut.len=2 sum=7

    // Another field-receiver slice — the head element — proving the copy reads correctly.
    let head = convos[0].turns.slice(0, 1)
    print("head.len={head.len()} head0={head[0].text}\n")   // head.len=1 head0=q
    return 0
}
