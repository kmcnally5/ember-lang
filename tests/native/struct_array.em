// struct_array.em — native differential test (OFI-054): arrays of structs. Covers a literal of
// value-structs, index read (a value COPY — mutating it leaves the array intact), .append,
// .remove_last (moves the element out), .len, .slice, and a heap-bearing element struct (a string
// field, so the per-element refcount discipline is exercised). The native backend stores these as
// inline-struct (packed) arrays; the VM is the reference — stdout must match bit-for-bit.
struct Pt {
    x: int
    y: int
}

struct Tag {
    id: int
    name: string
}

fn main() -> int {
    var pts = [Pt { x: 1, y: 2 }, Pt { x: 3, y: 4 }]
    pts.append(Pt { x: 5, y: 6 })
    var first = pts[0]
    first.x = 99                          // a COPY — pts[0] stays {1,2}
    let last = pts.remove_last()          // {5,6}, pts now len 2
    let mid = pts.slice(1, 2)             // [{3,4}]
    println("pts0={pts[0].x},{pts[0].y} first={first.x} last={last.x},{last.y}")
    println("len={pts.len()} mid={mid[0].x},{mid[0].y}")

    var tags: [Tag] = []
    tags.append(Tag { id: 1, name: "alpha" })
    tags.append(Tag { id: 2, name: "beta" })
    let t = tags[0]                       // a copy sharing the string (incref)
    let popped = tags.remove_last()       // Tag{2,"beta"} moves out
    println("t={t.id}:{t.name} ({t.name.len()}) popped={popped.id}:{popped.name}")

    // 1 + 2 + 99 + 5 + 6 + 2 + 3 + 1 + 2 + 5 = 126
    return pts[0].x + pts[0].y + first.x + last.x + last.y +
           pts.len() + mid[0].x + tags.len() + popped.id + t.name.len()
}
