// tests/run/map_array_value.em — OFI-063: a Map whose VALUE is an array (a "map of lists"), and
// arrays passed through erased generics. Arrays are unique-owner (like structs), so sharing one into
// an erased-generic aggregate must DEEP-CLONE it (value semantics), not alias-and-double-free. VM
// golden (the canonical backend; native support for Map-of-aggregate is a tracked follow-on).

import "std/map" as map

fn pair<T>(a: T, b: T) -> [T] { return [a, b] }

fn main() -> int {
    // Map<string, [int]> — set, overwrite, get; read elements back.
    var m = map.Map<string, [int]>{ buckets: [], count: 0 }
    m.set("a", [1, 2, 3])
    m.set("b", [10, 20])
    m.set("a", [7, 8, 9])
    match m.get("a") { case Some(v) { print("a:{v[0]}/{v[2]}/len{v.len()} ") } case None {} }
    match m.get("b") { case Some(v) { print("b:{v[0]}/{v[1]} ") } case None {} }
    match m.get("z") { case Some(v) { print("z?") } case None { print("z:none ") } }

    // arrays of arrays through an erased generic (the Map-free path).
    let xss = pair([1, 2], [3, 4, 5])
    print("xss:{xss[0].len()}/{xss[1].len()}")
    return 0
}
