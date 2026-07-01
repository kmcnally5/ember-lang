// M5k fixture for the self-hosted C-emit backend: fine-grained ownership around boxed-struct fields and
// method results (dogfooding the lexer down toward self-compilation). (1) a REFCOUNTED (string / enum)
// boxed-struct field CONSUMED by `+` is owned into the concat (`own_into_slot(&g_em, em_enum_field(…))`
// inside the balance-retain), not the plain borrow retain-dance a `==`/`!=` operand gets; (2) a string-
// returning METHOD result bound to a local (`let s = obj.method(…)`) is an OWNED string (dropped at scope
// exit, moved into a later call / struct field). Byte-identical to stage-0 `emberc --emit=c` (gated, Stage 6
// of make selfhost).
struct Pair {
    a: string
    b: string
}


fn joined(p: Pair) -> string {
    return p.a + p.b
}


struct Doc {
    title: string
    body: string

    fn head(self, n: int) -> string {
        return byte_slice(self.title, 0, n)
    }

    fn summary(self) -> string {
        return self.title + self.body
    }
}


fn describe(d: Doc) -> int {
    let h = d.head(2)
    let s = d.summary()
    return h.len() + s.len()
}


fn main() -> int {
    let p = Pair{a: "foo", b: "bar"}
    let d = Doc{title: "Ember", body: "lang"}
    let j = joined(p)
    return j.len() + describe(d)
}
