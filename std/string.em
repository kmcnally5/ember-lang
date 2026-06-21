// std/string.em — Ember's string library, written in Ember over the chars()
// intrinsic and the char_code/from_char_code/concat native primitives. Import it:
//     import "std/string" as str   ->   str.to_upper(s)
// UNICODE-AWARE: `s.chars()` is UTF-8 DECODED — one element per Unicode CODE POINT (an invalid
// byte yields U+FFFD), and `s.char_count()` is the code-point count. So every function here that
// works over chars() (substring, index_of, the `cp_*` caret helpers below) is CODE-POINT indexed,
// not byte indexed. The exception is `s.len()`, which is the BYTE length (for a multi-byte string
// it exceeds the code-point count) — use it for buffers/FFI, and `cp_count`/`char_count` for carets.
//
// Builders accumulate their pieces in a `[string]` and join them with one `concat`
// call (a single allocation + copy pass). Strings are immutable, so the naive
// `out = out + c` per character is O(n^2) — copying the whole prefix each step;
// this keeps every builder linear.
fn to_upper(s: string) -> string {
    let cs = s.chars()
    var out: [string] = []
    var i = 0
    loop {
        if i == cs.len() { return concat(out) }
        let code = char_code(cs[i])
        if code >= 97 && code <= 122 { out.append(from_char_code(code - 32)) }
        else { out.append(cs[i]) }
        i = i + 1
    }
    return concat(out)
}






fn to_lower(s: string) -> string {
    let cs = s.chars()
    var out: [string] = []
    var i = 0
    loop {
        if i == cs.len() { return concat(out) }
        let code = char_code(cs[i])
        if code >= 65 && code <= 90 { out.append(from_char_code(code + 32)) }
        else { out.append(cs[i]) }
        i = i + 1
    }
    return concat(out)
}






fn repeat(s: string, n: int) -> string {
    var out: [string] = []
    var i = 0
    loop {
        if i >= n { return concat(out) }   // OFI-103: >= so any n <= 0 terminates (== is never met for negative n)
        out.append(s)
        i = i + 1
    }
    return concat(out)
}






fn index_of(s: string, sub: string) -> int {
    let sc = s.chars()
    let bc = sub.chars()
    if bc.len() == 0 { return 0 }
    var i = 0
    loop {
        if i + bc.len() > sc.len() { return -1 }
        var j = 0
        var ok = true
        loop {
            if j == bc.len() { break }
            if sc[i + j] != bc[j] { ok = false  break }
            j = j + 1
        }
        if ok { return i }
        i = i + 1
    }
    return -1
}






fn contains(s: string, sub: string) -> bool {
    return index_of(s, sub) != -1
}






fn starts_with(s: string, prefix: string) -> bool {
    let sc = s.chars()
    let pc = prefix.chars()
    if pc.len() > sc.len() { return false }
    var i = 0
    loop {
        if i == pc.len() { return true }
        if sc[i] != pc[i] { return false }
        i = i + 1
    }
    return true
}






fn ends_with(s: string, suffix: string) -> bool {
    let sc = s.chars()
    let fc = suffix.chars()
    if fc.len() > sc.len() { return false }
    let off = sc.len() - fc.len()
    var i = 0
    loop {
        if i == fc.len() { return true }
        if sc[off + i] != fc[i] { return false }
        i = i + 1
    }
    return true
}






fn trim(s: string) -> string {
    let cs = s.chars()
    var start = 0
    var fin = cs.len()
    loop {
        if start == fin { return "" }
        let c = char_code(cs[start])
        if c == 32 || c == 9 || c == 10 || c == 13 { start = start + 1 } else { break }
    }
    loop {
        if fin == start { break }
        let c = char_code(cs[fin - 1])
        if c == 32 || c == 9 || c == 10 || c == 13 { fin = fin - 1 } else { break }
    }
    return substring(s, start, fin)
}






// substring returns the half-open range [start, end) of s (by char). Out-of-range
// bounds are clamped, and start >= end yields "" — never an index-out-of-bounds.
fn substring(s: string, start: int, end: int) -> string {
    let cs = s.chars()
    var lo = start
    var hi = end
    if lo < 0 { lo = 0 }
    if hi > cs.len() { hi = cs.len() }
    var out: [string] = []
    var i = lo
    loop {
        if i >= hi { return concat(out) }
        out.append(cs[i])
        i = i + 1
    }
    return concat(out)
}






// replace swaps every non-overlapping occurrence of `from` with `to`, scanning
// left to right. An empty `from` returns s unchanged (there is nothing to find).
// A single left-to-right pass over the characters (one chars() call), so it is
// linear regardless of how many matches there are — re-scanning the remainder per
// match (via index_of/substring) would make it O(n^2).
fn replace(s: string, from: string, to: string) -> string {
    if from.len() == 0 { return s }
    let sc = s.chars()
    let fc = from.chars()
    var out: [string] = []
    var i = 0
    loop {
        if i >= sc.len() { return concat(out) }
        var matched = false
        if i + fc.len() <= sc.len() {
            var j = 0
            var ok = true
            loop {
                if j == fc.len() { break }
                if sc[i + j] != fc[j] { ok = false  break }
                j = j + 1
            }
            matched = ok
        }
        if matched {
            out.append(to)
            i = i + fc.len()
        } else {
            out.append(sc[i])
            i = i + 1
        }
    }
    return concat(out)
}






// join concatenates parts with sep between them — the inverse of the `split`
// string intrinsic, so `join(s.split(sep), sep)` round-trips.
fn join(parts: [string], sep: string) -> string {
    var out: [string] = []
    var i = 0
    loop {
        if i == parts.len() { return concat(out) }
        if i > 0 { out.append(sep) }
        out.append(parts[i])
        i = i + 1
    }
    return concat(out)
}




// ---- code-point (caret) helpers -------------------------------------------------------------
// The canonical home for the Unicode-correct string edits a text caret needs (OFI-055): count,
// slice/prefix/at, and insert/delete at a code-point index. `chars()` is UTF-8 decoded, so these
// index by CODE POINT — a multi-byte character (é, 中, 😀) is one unit, never split. Indices are
// clamped, so an out-of-range index never traps. (std/ui's text_field and any app text input
// should build on these rather than re-implement them.)

// cp_count returns the number of Unicode code points in s — the caret's coordinate space.
fn cp_count(s: string) -> int {
    return s.char_count()
}






// cp_at returns the single code point at index i as a string, or "" if i is out of range.
fn cp_at(s: string, i: int) -> string {
    return substring(s, i, i + 1)
}






// cp_slice returns the code points in the half-open range [start, end) — the code-point view of
// `substring` (which is itself code-point indexed); bounds are clamped and start >= end yields "".
fn cp_slice(s: string, start: int, end: int) -> string {
    return substring(s, start, end)
}






// cp_prefix returns the first n code points of s (n past the end yields all of s; n <= 0 yields "").
// Used to measure a caret's x-offset: cp_prefix(s, caret).
fn cp_prefix(s: string, n: int) -> string {
    return substring(s, 0, n)
}






// cp_insert returns s with `ins` spliced in at code-point index idx. idx is clamped to
// [0, cp_count]: idx == cp_count (or past the end) appends, idx <= 0 prepends.
fn cp_insert(s: string, idx: int, ins: string) -> string {
    let cs = s.chars()
    var at = idx
    if at < 0 { at = 0 }
    if at > cs.len() { at = cs.len() }
    var out: [string] = []
    var i = 0
    loop {
        if i == at { out.append(ins) }
        if i == cs.len() { return concat(out) }
        out.append(cs[i])
        i = i + 1
    }
    return concat(out)
}






// cp_delete returns s with the code point at index idx removed (a no-op if idx is out of range).
fn cp_delete(s: string, idx: int) -> string {
    let cs = s.chars()
    var out: [string] = []
    var i = 0
    loop {
        if i == cs.len() { return concat(out) }
        if i != idx { out.append(cs[i]) }
        i = i + 1
    }
    return concat(out)
}
