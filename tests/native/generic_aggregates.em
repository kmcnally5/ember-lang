// tests/native/generic_aggregates.em — OFI-062/063: unique-owner aggregates (value structs AND
// arrays) shared through ERASED generics must be DEEP-CLONED (value semantics), not aliased — else
// two owners double-free / dangle. Runs on BOTH the VM and the compiled binary; the harness asserts
// identical stdout (the drift guard for own_into_slot / clone_owned_else_borrow across both backends).

import "std/map" as map

struct P { x: int  s: string }

fn pair<T>(a: T, b: T) -> [T] { return [a, b] }

fn main() -> int {
    // struct through a generic [T]
    let ps = pair(P { x: 10, s: "a" }, P { x: 20, s: "bb" })
    print("{ps[0].x}/{ps[0].s.len()},{ps[1].x}/{ps[1].s.len()} ")

    // ARRAY through a generic [T] (arrays are unique-owner too)
    let xss = pair([1, 2, 3], [9, 8])
    print("arr:{xss[0].len()},{xss[1].len()} ")

    // Map<string, struct value> (a table of records) — set, overwrite, get
    var ms = map.Map<string, P>{ buckets: [], count: 0 }
    ms.set("k", P { x: 1, s: "z" })
    ms.set("k", P { x: 99, s: "zz" })
    match ms.get("k") { case Some(v) { print("map:{v.x}/{v.s.len()} ") } case None {} }

    // Map<string, array value> (a map of lists)
    var ml = map.Map<string, [int]>{ buckets: [], count: 0 }
    ml.set("a", [5, 6, 7])
    ml.set("b", [8])
    match ml.get("a") { case Some(v) { print("ml:{v[0]}/{v.len()}") } case None {} }
    return 0
}
