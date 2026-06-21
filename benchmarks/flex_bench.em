// flex_bench.em — the whole-language speed benchmark. One run exercises every
// major subsystem, each section self-timed with clock() and CHECKSUMMED so a
// performance change that breaks semantics is caught by eye immediately:
//
//   1. arrays    — append-driven growth + indexed sweeps over a packed [int]
//   2. closures  — std/list map/filter/reduce pipelines (capturing lambdas)
//   3. sort      — generic comparator sort on pseudo-random ints + strings by length
//   4. map       — the hashed string-keyed Map: set/get/has through resize chains
//   5. strings   — std/string to_upper/replace/contains + split/join round-trips
//   6. structs   — struct construction, methods, field mutation, generic Box<T>
//   7. enums     — Option construction + exhaustive match in a hot loop
//   8. recursion — naive fib(30), the cross-benchmark anchor (see math_bench.em)
//
// Run it timed:   make bench        (or)
//                 time ./build/emberc-release --emit=run benchmarks/flex_bench.em
import "std/list" as list
import "std/map" as mp
import "std/string" as str


// A small deterministic LCG; every product stays far below the checked 64-bit
// range (seed < 2^31, multiplier < 2^31 -> product < 2^62).
fn lcg_next(seed: int) -> int {
    return (seed * 1103515245 + 12345) % 2147483648
}






struct Vec2 {
    x: float
    y: float

    fn dot(self, other: Vec2) -> float { return self.x * other.x + self.y * other.y }

    fn scale(mut self, k: float) {
        self.x = self.x * k
        self.y = self.y * k
    }
}






struct Box<T> {
    value: T

    fn get(self) -> T { return self.value }
}






fn fib(n: int) -> int {
    if n < 2 { return n }
    return fib(n - 1) + fib(n - 2)
}






fn main() -> int {
    println("=== Ember flex benchmark ===")
    let t0 = clock()

    // ---- 1. arrays: append growth + indexed sweeps --------------------------
    var t = clock()
    var data: [int] = []
    var seed = 42
    var i = 0
    loop {
        if i == 200000 { break }
        seed = lcg_next(seed)
        data.append(seed % 10000)
        i = i + 1
    }
    var sweep = 0
    var pass = 0
    loop {
        if pass == 5 { break }
        var j = 0
        loop {
            if j == data.len() { break }
            sweep = sweep + data[j]
            j = j + 1
        }
        pass = pass + 1
    }
    println("arrays    sum={sweep}  ({clock() - t}s)")

    // ---- 2. closures: map/filter/reduce pipeline ----------------------------
    t = clock()
    let offset = 7
    let mapped = list.map(data, |x| x * 2 + offset)
    let kept = list.filter(mapped, |x| x % 3 == 0)
    let folded = list.reduce(kept, 0, |acc, x| acc + x % 1000)
    println("closures  n={kept.len()} fold={folded}  ({clock() - t}s)")

    // ---- 3. sort: comparator closures, ints then strings --------------------
    t = clock()
    var unsorted: [int] = []
    i = 0
    loop {
        if i == 2000 { break }
        seed = lcg_next(seed)
        unsorted.append(seed % 100000)
        i = i + 1
    }
    let asc = list.sort(unsorted, |a, b| a < b)
    let desc = list.sort(unsorted, |a, b| a > b)
    var names: [string] = []
    i = 0
    loop {
        if i == 400 { break }
        seed = lcg_next(seed)
        names.append(str.repeat("n", seed % 17 + 1) + "{i}")
        i = i + 1
    }
    let bylen = list.sort(names, |a, b| a.len() < b.len())
    println("sort      lo={asc[0]} hi={desc[0]} short={bylen[0].len()}  ({clock() - t}s)")

    // ---- 4. map: hashed Map set/get/has through resizes ----------------------
    t = clock()
    var m = mp.Map<int> { buckets: [], count: 0 }
    i = 0
    loop {
        if i == 20000 { break }
        m.set("key{i % 5000}", i)            // 5000 distinct keys, 4 updates each
        i = i + 1
    }
    var hits = 0
    var got = 0
    i = 0
    loop {
        if i == 20000 { break }
        if m.has("key{i % 6000}") { hits = hits + 1 }
        match m.get("key{i % 6000}") {
            case Some(v) { got = got + v % 100 }
            case None { }
        }
        i = i + 1
    }
    println("map       size={m.size()} hits={hits} got={got}  ({clock() - t}s)")

    // ---- 5. strings: stdlib ops + split/join round-trips ---------------------
    t = clock()
    var scount = 0
    let sentence = "the quick brown fox jumps over the lazy dog"
    i = 0
    loop {
        if i == 1500 { break }
        let up = str.to_upper(sentence)
        let swapped = str.replace(sentence, "o", "0")
        if str.contains(up, "FOX") { scount = scount + 1 }
        if str.ends_with(swapped, "d0g") { scount = scount + 1 }
        let parts = sentence.split(" ")
        let joined = str.join(parts, "-")
        scount = scount + joined.len() % 10
        i = i + 1
    }
    println("strings   checks={scount}  ({clock() - t}s)")

    // ---- 6. structs: construction, methods, mutation, generics ---------------
    t = clock()
    var acc = 0.0
    i = 0
    loop {
        if i == 150000 { break }
        var v = Vec2 { x: to_float(i % 100), y: to_float(i % 50) }
        v.scale(1.5)
        let d = v.dot(Vec2 { x: 0.5, y: 2.0 })
        acc = acc + d
        i = i + 1
    }
    var boxed = 0
    i = 0
    loop {
        if i == 100000 { break }
        let b = Box<int> { value: i % 7 }
        boxed = boxed + b.get()
        i = i + 1
    }
    println("structs   acc={to_int(acc)} boxed={boxed}  ({clock() - t}s)")

    // ---- 7. enums: Option construction + match in a hot loop ------------------
    t = clock()
    var some_total = 0
    var nones = 0
    i = 0
    loop {
        if i == 300000 { break }
        var o: Option<int> = None
        if i % 3 != 0 { o = Some(i % 11) }
        match o {
            case Some(v) { some_total = some_total + v }
            case None { nones = nones + 1 }
        }
        i = i + 1
    }
    println("enums     total={some_total} nones={nones}  ({clock() - t}s)")

    // ---- 8. recursion: the cross-benchmark anchor -----------------------------
    t = clock()
    let f = fib(30)
    println("recursion fib(30)={f}  ({clock() - t}s)")

    println("TOTAL {clock() - t0}s")
    return 0
}
