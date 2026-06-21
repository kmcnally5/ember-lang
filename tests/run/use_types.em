// use_types.em — uses an imported type qualified (geom.Point) in an annotation and
// a parameter, constructs it via the library's constructor, and passes it back.
import "modlib/geom" as geom
fn total(p: geom.Point) -> int {
    return geom.sum(p)
}
fn main() -> int {
    let p: geom.Point = geom.make(3, 4)
    return total(p)        // 7
}
