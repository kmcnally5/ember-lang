// Native backend (M3c) differential test: the generic stdlib containers Set<K> and Map<K,V>
// over built-in (scalar/string) keys. These are BOUNDED generic structs (K: Hash + Eq): the
// key's Hash/Eq witnesses are stored as hidden trailing fields at construction and dispatched
// through native shims (rt_call_indirect → em_hash_any / em_value_eq). Map additionally stores
// its entries as STRUCTS inside a boxed `[Option<MapEntry>]`, exercising the value-struct<->
// boxed bridge for container payloads (box on construct, boxed field read). Covers dedup,
// table growth past the initial capacity, membership, update, and iteration.
import "std/set" as set
import "std/map" as mp

fn yn(b: bool) -> string {
    if b {
        return "Y"
    }
    return "N"
}

fn main() -> int {
    // Set<int>: dedup + growth past the initial table.
    var nums: set.Set<int> = set.Set<int> { slots: [], count: 0 }
    var i = 0
    loop {
        if i == 30 { break }
        nums.add(i * 2)
        i = i + 1
    }
    nums.add(10)                  // already present
    println("nums size={nums.size()} has10={yn(nums.has(10))} has11={yn(nums.has(11))}")

    // Map<string, int>: insert, update, get (Option), has, keys.
    var m: mp.Map<string, int> = mp.Map<string, int> { buckets: [], count: 0 }
    m.set("a", 1)
    m.set("b", 2)
    m.set("c", 3)
    m.set("b", 20)                // update
    println("map size={m.size()}")
    match m.get("b") {
        case Some(n) { println("b={n}") }
        case None    { println("b missing") }
    }
    var total = 0
    for k in m.keys() {
        match m.get(k) {
            case Some(n) { total = total + n }
            case None    { }
        }
    }
    println("total={total}")
    return nums.size() + m.size() + total
}
