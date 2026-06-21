// conditionals.em — locks the if/else jump layout (JUMP_IF_FALSE / POP / JUMP).
fn main() -> int {
    var x = 1
    if x == 1 {
        return 10
    } else {
        return 20
    }
}
