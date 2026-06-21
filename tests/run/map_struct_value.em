// tests/run/map_struct_value.em — OFI-062: Map<K, struct-value> (a table of records) works on the
// VM (the canonical backend). A value-struct VALUE is cloned into / out of the Map so unique-owner
// structs don't double-free. The struct carries a string field too, exercising the clone's boxed-
// leaf retain. (Native-backend support for the Map path is a tracked follow-on; this is a VM golden.)

import "std/map" as map

struct Rec {
    n: int
    tag: string
}

fn main() -> int {
    var m = map.Map<string, Rec>{ buckets: [], count: 0 }
    m.set("a", Rec { n: 10, tag: "alpha" })
    m.set("b", Rec { n: 20, tag: "beta" })
    m.set("a", Rec { n: 99, tag: "again" })
    match m.get("a") { case Some(r) { print("a={r.n}/{r.tag} ") } case None {} }
    match m.get("b") { case Some(r) { print("b={r.n}/{r.tag} ") } case None {} }
    match m.get("z") { case Some(r) { print("z?") } case None { print("z=none") } }
    return 0
}
