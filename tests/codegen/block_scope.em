// loop_block_local.em — a loop-body local that `break` must pop before jumping.
// If break failed to pop x, `return i` would return the leftover x (6) not 3.
fn main() -> int {
    var i = 0
    loop {
        let x = i * 2
        if x >= 6 { break }
        i = i + 1
    }
    return i
}
