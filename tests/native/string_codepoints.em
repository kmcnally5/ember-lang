// OFI-055 regression: std/string's Unicode code-point helpers. `chars()` is UTF-8 decoded, so
// cp_count/cp_at/cp_prefix/cp_slice/cp_insert/cp_delete index by CODE POINT — a multi-byte
// character (é = 2 bytes, 中 = 3, 😀 = 4) is one unit, never split. Indices are clamped (no trap).
// The exhaustive proof is the Python differential oracle (tools/string-diff.py); this is the
// always-on smoke regression with fixed, eyeballable expectations.
import "std/string" as str

fn main() -> int {
    let s = "aé中😀b"                          // 5 code points, 1+2+3+4+1 = 11 bytes

    println("count={str.cp_count(s)}")          // 5  (NOT s.len() == 11)
    println("bytes={s.len()}")                  // 11
    println("at0={str.cp_at(s, 0)}")            // a
    println("at2={str.cp_at(s, 2)}")            // 中
    println("at_oob={str.cp_at(s, 9)}")         // "" (out of range, clamped)
    println("prefix3={str.cp_prefix(s, 3)}")    // aé中
    println("slice1_4={str.cp_slice(s, 1, 4)}") // é中😀
    println("insert_mid={str.cp_insert(s, 2, "X")}")   // aéX中😀b
    println("insert_end={str.cp_insert(s, 5, "!")}")   // aé中😀b!   (idx == count appends)
    println("insert_past={str.cp_insert(s, 99, "?")}") // aé中😀b?   (clamped to the end)
    println("insert_neg={str.cp_insert(s, -3, "<")}")  // <aé中😀b    (clamped to the front)
    println("delete2={str.cp_delete(s, 2)}")    // aé😀b      (drops 中, the 3-byte char)
    println("delete_oob={str.cp_delete(s, 99)}")// aé中😀b     (no-op)
    println("empty_count={str.cp_count("")}")   // 0
    return 0
}
