// tests/graphics/flare_dock.em — regression for std/flare's DockTree (the retained dock layout model).
// A DockTree is an app-owned binary tree of split containers + panel leaves (parallel-array slotmap).
// Pure data, no rendering. Locks in: add_root; split() docking a panel beside a leaf (with correct
// left-to-right leaf order); close() removing a leaf AND collapsing its parent split (node count drops
// by 2); node accounting returning to 0 with no leaked nodes when emptied; and the DockTree↔Flare wiring
// — close() returns the removed panel id so the app disposes that panel's state via f.forget(id).
import "std/flare" as flare

fn join(xs: [string]) -> string {
    var s = ""
    var i = 0
    loop {
        if i == xs.len() { break }
        if i > 0 { s = s + "," }
        s = s + xs[i]
        i = i + 1
    }
    return s
}

fn main() -> int {
    var f = flare.new()
    var t = flare.dock_new()

    let editor = t.add_root("editor")
    println("root: [{join(t.leaves())}] nodes={t.node_count()}")

    let sidebar = t.split(editor, "sidebar", true, 0.25)    // editor | sidebar (vertical divider)
    let term = t.split(editor, "terminal", false, 0.7)      // editor / terminal (stacked)
    println("split: [{join(t.leaves())}] nodes={t.node_count()}")

    // give two panels state, then close the terminal and dispose its state
    f.key("terminal")  f.set_int("scroll", 99)
    f.key("sidebar")   f.set_int("width", 240)

    let closed = t.close(term)
    f.forget(closed)
    println("close {closed}: [{join(t.leaves())}] nodes={t.node_count()}")

    f.key("terminal")  let ts = f.state_int("scroll", -1)   // disposed -> default
    f.key("sidebar")   let sw = f.state_int("width", -1)    // intact
    println("state: terminal.scroll={ts} sidebar.width={sw}")

    let c2 = t.close(sidebar)  f.forget(c2)
    let c3 = t.close(editor)   f.forget(c3)
    println("empty: [{join(t.leaves())}] nodes={t.node_count()} root={t.root}")
    return 0
}
