// field_mutation_nested.em — assignment to a nested field path.
struct Inner { v: int }
struct Outer { i: Inner }
fn main() -> int {
    var o = Outer { i: Inner { v: 1 } }
    o.i.v = 7
    return o.i.v
}
