// stdlib_set.em — exercises std/set: dedup, membership, growth past the initial table, and
// iteration, over both string and int keys.
import "std/set" as st


fn yn(b: bool) -> string {
    if b { return "Y" }
    return "N"
}


fn main() -> int {
    // String keys: duplicates collapse.
    var words: st.Set<string> = st.Set<string> { slots: [], count: 0 }
    words.add("red")
    words.add("green")
    words.add("red")          // dup — no-op
    words.add("blue")
    println("words={words.size()} red={yn(words.has("red"))} pink={yn(words.has("pink"))}")
    // words=3 red=Y pink=N

    // Int keys, enough to force at least one resize (8-slot table, 0.7 load factor).
    var nums: st.Set<int> = st.Set<int> { slots: [], count: 0 }
    var i = 0
    loop {
        if i == 20 { break }
        nums.add(i * 2)       // 0,2,4,...,38 — 20 distinct evens
        i = i + 1
    }
    nums.add(10)              // already present — no-op
    println("nums={nums.size()} has10={yn(nums.has(10))} has11={yn(nums.has(11))}")
    // nums=20 has10=Y has11=N

    // items() returns every key; sum them to confirm all survived the resizes.
    var total = 0
    for k in nums.items() {
        total = total + k
    }
    println("sum={total}")    // 0+2+...+38 = 380

    return words.size() + nums.size()   // 3 + 20 = 23
}
