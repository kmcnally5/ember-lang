// precedence.em — locks that the VM honours operator precedence at runtime:
// 2 + 3 * 4 = 14, not 20.
fn main() -> int {
    return 2 + 3 * 4
}
