// stdlib_map.em — the Map<V> stdlib type (string-keyed), now a real file under std/
// pulled in with `import`. Exercises set (insert + update), get, has, size, keys —
// and so the cross-module path: qualified generic construction + methods + Option.
import "std/map" as mp
fn main() -> int {
    var m = mp.Map<string, int> { buckets: [], count: 0 }
    m.set("a", 1)
    m.set("b", 2)
    m.set("c", 3)
    m.set("b", 20)                         // update, not insert
    println("size={m.size()}")            // 3
    match m.get("b") { case Some(n) { println("b={n}") } case None { } }   // 20
    if m.has("a") { println("has a") }
    if m.has("z") { println("has z") } else { println("no z") }
    var total = 0
    let ks = m.keys()                      // bucket order (hashed) — sum is order-free
    var i = 0
    loop {
        if i == ks.len() { break }
        match m.get(ks[i]) { case Some(n) { total = total + n } case None { } }
        i = i + 1
    }
    println("total={total}")              // 1 + 20 + 3 = 24
    return m.size() + total                // 3 + 24 = 27
}
