// tests/native/match_bind_clone.em — OFI-064: binding a value-struct out of a `match` case into an
// OUTER owner must DEEP-COPY it (value semantics), not alias the scrutinee's payload — else the two
// owners double-free at drop. The fix lives in the checker (consume() marks the borrowed read
// moves_local == 2), so it feeds BOTH backends; this runs on the VM and the compiled binary and the
// harness asserts identical stdout. The test is discriminating: mutating the copy must leave the
// source untouched, so an alias regression changes the output (or crashes at teardown).

import "std/map" as map

struct Box { n: int }

struct Inner { k: int }

struct Nest { n: int  inner: Inner }    // NON-FLAT: a nested struct field, stored boxed in aggregates


fn main() -> int {
    // (1) Option<struct>: bind the payload to a pre-existing var, then mutate the copy.
    let o: Option<Box> = Some(Box { n: 1 })
    var a = Box { n: 0 }
    match o { case Some(v) { a = v } case None {} }
    a.n = 42
    var on = 0
    match o { case Some(v) { on = v.n } case None {} }   // o stays 1 if cloned; 42 if aliased
    print("bind:o={on}/a={a.n} ")

    // (2) Map<int, struct> read-modify-writeback (the window-registry shape): get into a local,
    // mutate it, set it back; the map's stored record must be an independent copy.
    var m = map.Map<int, Box>{ buckets: [], count: 0 }
    m.set(7, Box { n: 5 })
    var b = Box { n: 0 }
    match m.get(7) { case Some(w) { b = w } case None {} }
    b.n = 99
    var mn = 0
    match m.get(7) { case Some(w) { mn = w.n } case None {} }   // map stays 5 if cloned
    print("map:m={mn}/b={b.n} ")

    // (3) read-modify-writeback round-trip: the value written back must survive and be distinct.
    var c = Box { n: 0 }
    match m.get(7) { case Some(w) { c = w } case None {} }
    c.n = c.n + 1
    m.set(7, c)
    var fin = 0
    match m.get(7) { case Some(w) { fin = w.n } case None {} }
    print("rmw:{fin} ")

    // (4) NON-FLAT struct (nested field) bound out of a match into an outer var — the shape that
    // exposed the native unbox-coercion gap (the boxed payload must unbox into the em_s local).
    let no: Option<Nest> = Some(Nest { n: 3, inner: Inner { k: 4 } })
    var nd = Nest { n: 0, inner: Inner { k: 0 } }
    match no { case Some(v) { nd = v } case None {} }
    nd.n = nd.n + 10
    var src = 0
    match no { case Some(v) { src = v.n } case None {} }   // source untouched: stays 3
    print("nest:nd={nd.n}/{nd.inner.k} src={src}")
    return 0
}
