// map_int_keys.em — the generic Map<K,V> with NON-string keys (the new capability).
// int keys, exercised through enough inserts to force a resize, plus update + miss.
import "std/map" as mp
fn main() -> int {
    var m = mp.Map<int, int> { buckets: [], count: 0 }
    var i = 0
    loop {
        if i == 30 { break }
        m.set(i * 7, i)          // 30 distinct int keys -> forces resizes
        i = i + 1
    }
    m.set(0, 100)                // update key 0 (was i=0 -> val 0)
    var total = 0
    var k = 0
    loop {
        if k == 30 { break }
        match m.get(k * 7) { case Some(v) { total = total + v } case None { } }
        k = k + 1
    }
    var miss = 0
    match m.get(99999) { case Some(v) { miss = 1 } case None { miss = 0 } }   // absent
    // sum of i for i=1..29 is 435; key 0 now holds 100; so total = 435 + 100 = 535
    return m.size() + total + miss   // 30 + 535 + 0 = 565
}
