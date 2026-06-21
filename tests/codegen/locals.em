// locals.em — locks the bytecode for local declaration (slot reuse of the
// initialiser's stack position), GET_LOCAL/SET_LOCAL/POP, and assignment.
fn main() -> int {
    let a = 1
    var b = 2
    b = a + b
    return b
}
