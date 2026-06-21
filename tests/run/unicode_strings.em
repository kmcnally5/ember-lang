// unicode_strings.em — UTF-8 code-point string operations (language.md). Strings store UTF-8
// bytes; .len()/.bytes() are byte-level (O(1) storage / FFI), while .chars()/.char_count()/
// char_code()/from_char_code() work at Unicode CODE-POINT granularity. é is 2 bytes (U+00E9),
// → is 3 (U+2192), 🚀 is 4 (U+1F680) — so byte length and code-point count diverge.
fn main() -> int {
    let s = "café"
    println("bytes={s.len()} chars={s.char_count()}")     // bytes=5 chars=4

    let cs = s.chars()                                     // ["c","a","f","é"]
    println("chars_len={cs.len()} last={cs[3]}")           // chars_len=4 last=é
    println("raw_bytes={s.bytes().len()}")                 // raw_bytes=5

    // code-point round-trips (not byte values)
    println("code_e={char_code("é")}")                     // 233
    println("from_233={from_char_code(233)}")              // é

    let rocket = from_char_code(128640)                    // U+1F680 🚀
    println("rocket={rocket} cp={char_code(rocket)} rbytes={rocket.len()}")  // 🚀 128640 4

    // split on a multibyte separator (→ is 3 bytes; UTF-8 is self-synchronizing)
    let parts = "a→b→c".split("→")
    println("parts={parts.len()} mid={parts[1]}")          // parts=3 mid=b

    return s.char_count() + rocket.len()                   // 4 + 4 = 8
}
