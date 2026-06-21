// stdlib_string_more.em — the second wave of std/string: ends_with, substring,
// replace, join. Also covers the same-module-call refactors (contains -> index_of,
// trim -> substring) that the file-based stdlib layout unlocked.
import "std/string" as str
fn main() -> int {
    var n = 0
    if str.ends_with("hello.em", ".em")        { n = n + 1 }   // 1
    if !str.ends_with("hello", "xyz")          { n = n + 1 }   // 2
    if str.substring("Ember", 1, 4) == "mbe"   { n = n + 1 }   // 3
    if str.substring("Ember", 0, 99) == "Ember" { n = n + 1 }  // 4  (hi clamped)
    if str.substring("Ember", 3, 1) == ""      { n = n + 1 }   // 5  (start >= end)
    if str.replace("a.b.c", ".", "/") == "a/b/c" { n = n + 1 } // 6
    if str.replace("aaa", "a", "xx") == "xxxxxx" { n = n + 1 }  // 7  (no re-match of `to`)
    if str.replace("none", "", "x") == "none"  { n = n + 1 }   // 8  (empty `from` is a no-op)
    if str.join("a b c".split(" "), "-") == "a-b-c" { n = n + 1 } // 9
    if str.join("solo".split(","), "-") == "solo" { n = n + 1 }   // 10 (single part)
    if str.contains("hello world", "world")    { n = n + 1 }   // 11 (refactored)
    if str.trim("  hi  ") == "hi"              { n = n + 1 }   // 12 (refactored)
    println("checks={n}")
    return n                                                    // 12
}
