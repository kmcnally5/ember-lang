// struct_value_local.em — value-types 3b: an immutable all-scalar struct bound with `let`
// is stored MULTI-SLOT (its fields exploded onto the stack, no heap object). Such a binding
// is a VALUE TYPE — reading it copies (the source stays usable), field access reads a slot
// directly, and it crosses into still-boxed territory (call args, method receivers, array
// elements, enum payloads) through a box/unbox seam. A double-free would corrupt the result;
// a leak is checked out-of-suite by RSS staying flat. (`var` and boxed-field structs stay boxed.)
struct V {
    x: int
    y: int
    z: int


    fn s(self) -> int {
        return self.x + self.y + self.z
    }
}


fn sum(v: V) -> int {
    return v.x + v.y + v.z
}


fn unwrap(o: Option<V>) -> int {
    match o {
        case Some(q) { return q.s() }
        case None { return 0 }
    }
}


fn main() -> int {
    let v = V { x: 1, y: 2, z: 3 }       // multi-slot local
    let w = v                            // COPY — v stays usable (value semantics)
    let fields = v.x + v.y + w.z         // 1 + 2 + 3   field reads from slots
    let viaArg = sum(w)                  // 6   box-on-use into a boxed param
    let viaMethod = v.s()                // 6   box-on-use receiver
    let arr = [v, V { x: 4, y: 5, z: 6 }] // box-on-use into inline-array elements
    let viaArr = arr[0].x + arr[1].z     // 1 + 6
    let viaOpt = unwrap(Some(w))         // 6   box-on-use into an enum payload
    return fields + viaArg + viaMethod + viaArr + viaOpt   // 6+6+6+7+6 = 31
}
