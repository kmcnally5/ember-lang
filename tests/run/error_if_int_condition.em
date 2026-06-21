// error_if_int_condition.em — locks strict typing: an int is not a bool, so an
// integer 'if' condition is a compile error (no truthiness/coercion).
fn main() -> int {
    if 1 {
        return 1
    }
    return 0
}
