// OFI-042 regression: user structs as Map/Set keys. A move-type struct key needs no `Copy`
// bound — the map/set deep-clone it structurally on store (sound, no double-free; VM==native +
// ASan-clean). Covers an int-field key (resize + update), a string-field key (refcount path),
// and a Set with duplicate adds.
import "std/map" as map
import "std/set" as set

struct Pt implements Hash, Eq {
    x: int
    y: int
    fn hash(self) -> int { return self.x * 31 + self.y }
    fn eq(self, other: Pt) -> bool { return self.x == other.x && self.y == other.y }
}

struct Name implements Hash, Eq {
    first: string
    n: int
    fn hash(self) -> int { return self.n }
    fn eq(self, other: Name) -> bool { return self.n == other.n }
}

fn main() -> int {
    // Map with an int-field struct key: 20 inserts force several resizes; then update one key.
    var m = map.Map<Pt, int>{ buckets: [], count: 0 }
    var i = 0
    loop {
        if i == 20 { break }
        m.set(Pt { x: i, y: i + 1 }, i * 100)
        i = i + 1
    }
    m.set(Pt { x: 3, y: 4 }, 999)          // update, not insert
    var msum = 0
    var j = 0
    loop {
        if j == 20 { break }
        match m.get(Pt { x: j, y: j + 1 }) {
            case Some(v) { msum = msum + v }
            case None { msum = msum + 1000000 }
        }
        j = j + 1
    }

    // Map with a string-field struct key (exercises the refcount clone path).
    var nm = map.Map<Name, int>{ buckets: [], count: 0 }
    var k = 0
    loop {
        if k == 12 { break }
        nm.set(Name { first: "person_{k}", n: k }, k * 10)
        k = k + 1
    }
    var nsum = 0
    var q = 0
    loop {
        if q == 12 { break }
        match nm.get(Name { first: "lookup", n: q }) {
            case Some(v) { nsum = nsum + v }
            case None {}
        }
        q = q + 1
    }

    // Set with a struct key: duplicate adds collapse to one.
    var s = set.Set<Pt>{ slots: [], count: 0 }
    var a = 0
    loop {
        if a == 15 { break }
        s.add(Pt { x: a, y: a })
        a = a + 1
    }
    s.add(Pt { x: 3, y: 3 })               // dup
    var hits = 0
    var b = 0
    loop {
        if b == 15 { break }
        if s.has(Pt { x: b, y: b }) { hits = hits + 1 }
        b = b + 1
    }

    println("map size={m.size()} msum={msum}")
    println("name size={nm.size()} nsum={nsum}")
    println("set size={s.size()} hits={hits}")
    return 0
}
