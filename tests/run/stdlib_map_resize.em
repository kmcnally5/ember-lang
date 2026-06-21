// stdlib_map_resize.em — drives the hashed Map past several 0.7-load doublings
// (8 -> 16 -> 32 -> 64) and confirms nothing is lost across the rehashes: every
// key still resolves, updates are seen, and the count is exact.
import "std/map" as mp
fn main() -> int {
    var m = mp.Map<string, int> { buckets: [], count: 0 }
    var i = 0
    loop {
        if i == 40 { break }
        m.set("k{i}", i)                 // 40 distinct keys -> forces 3 resizes
        i = i + 1
    }
    m.set("k5", 500)                     // update an existing key (no count change)
    m.set("k39", 390)                    // update the last inserted key too

    println("size={m.size()}")          // 40

    // Sum every value back through get(): 0+1+..+39 = 780, minus the two updated
    // originals (5, 39) plus their new values (500, 390): 780 - 44 + 890 = 1626.
    var total = 0
    let ks = m.keys()
    var j = 0
    loop {
        if j == ks.len() { break }
        match m.get(ks[j]) { case Some(v) { total = total + v } case None { } }
        j = j + 1
    }
    println("total={total}")            // 1626

    // A miss after all the resizing still returns None.
    match m.get("absent") { case Some(v) { return -1 } case None { } }
    if m.has("k0") && m.has("k39") && !m.has("k40") {
        return m.size() + total          // 40 + 1626 = 1666
    }
    return -2
}
