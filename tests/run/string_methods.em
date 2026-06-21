// string_methods.em — byte-wise string operations: len, chars, split, parse_int.
// split returns a [string] (a growable array), chars returns a [string] of single
// bytes, parse_int returns the program's Option (Some(n) / None on malformed or
// out-of-range input). These compose with arrays and match for real text work.
enum Option<T> { Some(value: T)  None }

fn sum_csv(csv: string) -> int {            // parse and sum a comma-separated list
    var total = 0
    let parts = csv.split(",")
    var i = 0
    loop {
        if i == parts.len() { return total }
        match parts[i].parse_int() {
            case Some(n) { total = total + n }
            case None    { }                // skip non-numeric fields
        }
        i = i + 1
    }
    return total
}

fn count_char(s: string, target: string) -> int {   // count a single-byte char
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
    let total = sum_csv("10,20,3,bad,9")    // 10 + 20 + 3 + 9 = 42 (bad → None)
    let text = "mississippi"
    let s_count = count_char(text, "s")     // 4
    return total + s_count + text.len()     // 42 + 4 + 11 = 57
}
