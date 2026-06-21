// nonflat_struct.em — native differential test (OFI-054): a NON-FLAT struct (one with a nested
// inline-struct field) exercised across every boxed-aggregate path that previously errored —
// array element, enum payload, an interface (dyn dispatch), and an erased generic by value — plus
// a struct that has BOTH an inline-struct field and a heap (string) field, to cover the combined
// place/read/drop discipline. The VM is the reference; stdout must match bit-for-bit, leak-free.
enum Option<T> { Some(value: T)  None }

interface Spanned { fn span(self) -> int }

struct Pt { x: int  y: int }

struct Seg implements Spanned {
    a: Pt
    b: Pt

    fn span(self) -> int { return (self.b.x - self.a.x) + (self.b.y - self.a.y) }
}

struct Rec {                       // a non-flat struct with BOTH an inline-struct AND a heap field
    p: Pt
    name: string
}

fn spanned<T>(f: fn(T) -> int, x: T) -> int { return f(x) }   // erased generic over a non-flat T

fn main() -> int {
    // Array of non-flat structs + nested field reads off a boxed element.
    let segs = [Seg { a: Pt { x: 0, y: 0 }, b: Pt { x: 3, y: 4 } },
                Seg { a: Pt { x: 1, y: 1 }, b: Pt { x: 2, y: 5 } }]
    // Erased generic HOF taking a non-flat struct BY VALUE (boxed for the closure, unboxed inside).
    let g = spanned(|sg| sg.b.x - sg.a.x, Seg { a: Pt { x: 1, y: 0 }, b: Pt { x: 8, y: 0 } })
    println("g={g} a={segs[1].a.x},{segs[1].a.y} b={segs[1].b.y}")   // g=7

    // Dyn dispatch on a non-flat struct (interface upcast + vtable call).
    let shape: Spanned = Seg { a: Pt { x: 2, y: 2 }, b: Pt { x: 8, y: 6 } }
    println("dyn={shape.span()}")      // (8-2)+(6-2) = 10

    // Non-flat struct as an enum payload, bound + read back.
    let opt = Some(Pt { x: 5, y: 9 })
    match opt {
        case Some(p) { println("opt={p.x},{p.y}") }
        case None    { println("none") }
    }

    // A struct with an inline-struct field AND a heap field, in an array (read fields in place —
    // a whole struct can't be moved out of an array element).
    var recs: [Rec] = []
    recs.append(Rec { p: Pt { x: 7, y: 8 }, name: "alpha" })
    println("rec={recs[0].p.x},{recs[0].p.y} {recs[0].name} ({recs[0].name.len()})")

    return g + shape.span() + recs[0].p.x + recs.len()   // 7 + 10 + 7 + 1 = 25
}
