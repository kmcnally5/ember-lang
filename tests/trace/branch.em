// branch.em — locks the execution tape: per-instruction events with source
// lines and stack snapshots, through a comparison + if + assignment.
fn main() -> int {
    var x = 2
    if x > 1 {
        x = x + 3
    }
    return x
}
