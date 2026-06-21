// stdlib_string_concat.em — the concat([string]) native and the linear-builder
// rewrites it backs. Covers concat directly (incl. empty parts and empty array),
// many-match replace (the case whose remainder-rescan was quadratic), and that the
// rebuilt builders still agree with their definitions on non-trivial input.
import "std/string" as str
fn main() -> int {
    var n = 0

    // concat: one allocation, parts joined in order; empty parts vanish.
    if concat(["foo", "", "bar", "baz"]) == "foobarbaz" { n = n + 1 }   // 1
    let empty: [string] = []
    if concat(empty) == "" { n = n + 1 }                                // 2
    if concat(["solo"]) == "solo" { n = n + 1 }                         // 3

    // replace, many non-overlapping matches in one pass.
    if str.replace("a.b.c.d.e", ".", "/") == "a/b/c/d/e" { n = n + 1 }  // 4
    if str.replace("aaaa", "a", "xx") == "xxxxxxxx" { n = n + 1 }       // 5  (no re-match of `to`)
    if str.replace("aXaXa", "X", "") == "aaa" { n = n + 1 }            // 6  (delete)
    if str.replace("none", "z", "Q") == "none" { n = n + 1 }           // 7  (no match)

    // the rebuilt builders, on a longer string.
    let base = str.repeat("Ab9 ", 50)              // 200 chars, 50 reps
    if base.len() == 200 { n = n + 1 }                                  // 8
    let up = str.to_upper(base)
    let lo = str.to_lower(base)
    if str.contains(up, "AB9") && str.contains(lo, "ab9") { n = n + 1 } // 9
    if str.substring(up, 0, 3) == "AB9" { n = n + 1 }                   // 10
    if str.join(base.split(" "), "-").len() > 0 { n = n + 1 }           // 11
    if str.trim("   x y   ") == "x y" { n = n + 1 }                     // 12

    println("checks={n}")
    return n                                                            // 12
}
