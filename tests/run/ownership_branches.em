// ownership_branches.em — the same value may be moved in different branches; the
// move-state is merged across them (moved on either path, but they are exclusive).
struct Point { x: int  y: int }
fn main() -> int {
    var p = Point { x: 3, y: 4 }
    var c = 1
    if c == 1 {
        let a = p
        return a.x
    } else {
        let b = p
        return b.y
    }
    return -1
}
