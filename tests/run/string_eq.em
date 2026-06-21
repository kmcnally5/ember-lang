// string_eq.em — string content equality (concatenation equals the literal).
fn main() -> int {
    if "ab" + "c" == "abc" {
        return 1
    }
    return 0
}
