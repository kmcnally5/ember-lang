// map_remove.em — regression for Map.remove (std/map.em). Linear-probe deletion must
// re-home the cluster that follows a removed slot, or a colliding key pushed past it
// would be lost. Exercises scattered removal across a resize, slot reuse, absent/double
// remove, and struct-valued maps (drop discipline). Output is deterministic: keys are
// queried in index order, never via bucket-order keys().

import "std/map" as mp

struct Pair {
    a: int
    b: int
}

fn yn(b: bool) -> string {
    if b {
        return "T"
    }
    return "F"
}

fn main() -> int {
    var m = mp.Map<string, int>{ buckets: [], count: 0 }
    var i = 0
    loop {
        if i == 12 { break }
        m.set("k{i}", i)
        i = i + 1
    }
    println("inserted size={m.size()}")

    // Remove a scattered middle subset — keys probed past these must survive.
    var removed = 0
    if m.remove("k3") { removed = removed + 1 }
    if m.remove("k4") { removed = removed + 1 }
    if m.remove("k7") { removed = removed + 1 }
    println("removed {removed} size={m.size()}")

    var line = ""
    i = 0
    loop {
        if i == 12 { break }
        match m.get("k{i}") {
            case Some(v) { line = line + "k{i}={v} " }
            case None { line = line + "k{i}=_ " }
        }
        i = i + 1
    }
    println(line)

    // Slot reuse (re-add a removed key) and in-place update of a survivor.
    m.set("k4", 400)
    m.set("k0", 99)
    var k4 = "_"
    match m.get("k4") {
        case Some(v) { k4 = "{v}" }
        case None {}
    }
    var k0 = "_"
    match m.get("k0") {
        case Some(v) { k0 = "{v}" }
        case None {}
    }
    println("reuse k4={k4} update k0={k0} size={m.size()}")

    let absent = m.remove("nope")
    let first  = m.remove("k1")
    let second = m.remove("k1")
    println("absent={yn(absent)} first={yn(first)} second={yn(second)} size={m.size()}")

    // Struct-valued map: removing must drop the Pair value cleanly, survivors intact.
    var sm = mp.Map<string, Pair>{ buckets: [], count: 0 }
    i = 0
    loop {
        if i == 8 { break }
        sm.set("p{i}", Pair{ a: i, b: i * i })
        i = i + 1
    }
    var sremoved = 0
    if sm.remove("p2") { sremoved = sremoved + 1 }
    if sm.remove("p5") { sremoved = sremoved + 1 }
    var sl = ""
    i = 0
    loop {
        if i == 8 { break }
        match sm.get("p{i}") {
            case Some(p) { sl = sl + "p{i}.b={p.b} " }
            case None { sl = sl + "p{i}=_ " }
        }
        i = i + 1
    }
    println(sl)
    println("struct size={sm.size()} removed={sremoved}")
    return 0
}
