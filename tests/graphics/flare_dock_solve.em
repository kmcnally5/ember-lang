// tests/graphics/flare_dock_solve.em — regression for DockTree.solve() (the dock layout geometry).
// solve() walks the split tree top-down, dividing each split's rect along its axis by `ratio` with an
// 8px divider gap; leaves take their rect whole. Pure geometry, deterministic, no rendering — this
// locks the recursive division math (nesting, ratios, gaps) independent of the renderer or fonts.
import "std/flare" as flare

fn main() -> int {
    var t = flare.dock_new()
    let editor = t.add_root("editor")
    let sidebar = t.split(editor, "sidebar", true, 0.25)   // editor(A)=25% | sidebar(B)=75%
    let term = t.split(editor, "terminal", false, 0.7)     // editor(A)=70% / terminal(B)=30%
    t.solve(0, 0, 1000, 600)
    var i = 0
    loop {
        if i == t.dk_kind.len() { break }
        if t.dk_kind[i] == 1 {
            println("{t.dk_panel[i]}: x={t.dk_x[i]} y={t.dk_y[i]} w={t.dk_w[i]} h={t.dk_h[i]}")
        }
        i = i + 1
    }
    return 0
}
