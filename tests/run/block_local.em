// block_local.em — a `let` inside an if-block, used within it; scope exits cleanly.
fn main() -> int {
    var r = 0
    if true {
        let x = 42
        r = x
    }
    return r
}
