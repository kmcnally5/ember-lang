// Native backend (M5) differential test: string methods over UTF-8 bytes/code points.
// Covers .chars() (a [string] of code points), .split(sep) (a [string] of pieces),
// .parse_int() (Option<int>), .char_count() and .bytes(). These compose with array
// indexing, len(), and match — the drop discipline must keep every borrowed element
// alive (em_index borrows; an alias into a new owner retains). Output must match the VM.
enum Option<T> { Some(value: T)  None }

fn sum_csv(csv: string) -> int {
    var total = 0
    let parts = csv.split(",")
    var i = 0
    loop {
        if i == parts.len() { return total }
        match parts[i].parse_int() {
            case Some(n) { total = total + n }
            case None    { }
        }
        i = i + 1
    }
    return total
}

fn count_byte(s: string, target: string) -> int {
    var count = 0
    let cs = s.chars()
    var i = 0
    loop {
        if i == cs.len() { return count }
        if cs[i] == target { count = count + 1 }
        i = i + 1
    }
    return count
}

fn main() -> int {
    let total = sum_csv("10,20,3,bad,9")     // 42 (bad -> None)
    let text = "mississippi"
    let sc = count_byte(text, "s")           // 4
    println("split sum = {total}")
    println("s count = {sc}")
    println("char_count = {text.char_count()}")            // 11
    println("bytes len = {text.bytes().len()}")            // 11
    let chars = text.chars()
    println("first char = {chars[0]}")                     // m
    return total + sc + text.len()           // 42 + 4 + 11 = 57
}
