// error_redeclare.em — redeclaring a name in the same scope is an error
// (shadowing across scopes is allowed; this is not that).
fn main() -> int {
    let x = 1
    let x = 2
    return x
}
