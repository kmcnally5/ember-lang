// error_assign_to_let.em — locks the immutability rule: assigning to a `let`
// binding is a compile error (the golden captures the diagnostic + that no
// value is produced).
fn main() -> int {
    let a = 5
    a = 6
    return a
}
