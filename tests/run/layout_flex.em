// tests/run/layout_flex.em — std/layout flexbox solver (MANIFESTO §5g). Builds known trees and
// prints the solved rectangles, so the layout maths is regression-locked without a window (the
// solver is pure). Covers nesting, padding, gap, justify (start/center/end/between), align
// (center/stretch), and grow. Hand-verifiable against the geometry in the comments.

import "std/layout" as L

fn rect(lay: L.Layout, name: string, i: int) {
    print("{name} {lay.x(i)},{lay.y(i)},{lay.w(i)},{lay.h(i)}\n")
}

fn main() -> int {
    // 1) A padded column (pad 10, gap 10) holding a toolbar row (title left, button right via
    //    justify=between, vertically centred) and a body that grows to fill the rest.
    var a = L.new()
    let root = a.open(L.COL, L.START, L.STRETCH, 10, 10)
    let bar  = a.open(L.ROW, L.BETWEEN, L.CENTER, 0, 0)
    let title = a.leaf(100, 20, 0)
    let btn   = a.leaf(60, 30, 0)
    a.close()
    let body = a.leaf(0, 50, 1)
    a.close()
    a.solve(0, 0, 400, 200)
    rect(a, "root", root)
    rect(a, "bar", bar)
    rect(a, "title", title)
    rect(a, "btn", btn)
    rect(a, "body", body)

    // 2) justify=center in a 200-wide row: two 40px leaves with a 10px gap centre as a group.
    var b = L.new()
    b.open(L.ROW, L.CENTER, L.START, 10, 0)
    let bc1 = b.leaf(40, 20, 0)
    let bc2 = b.leaf(40, 20, 0)
    b.close()
    b.solve(0, 0, 200, 50)
    rect(b, "center1", bc1)
    rect(b, "center2", bc2)

    // 3) justify=end packs the same pair against the right edge.
    var c = L.new()
    c.open(L.ROW, L.END, L.START, 10, 0)
    let cc1 = c.leaf(40, 20, 0)
    let cc2 = c.leaf(40, 20, 0)
    c.close()
    c.solve(0, 0, 200, 50)
    rect(c, "end1", cc1)
    rect(c, "end2", cc2)
    return 0
}
