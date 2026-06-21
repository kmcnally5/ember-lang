// tests/graphics/flare_nav_item.em — regression for f.nav_item (the full-width sidebar nav row + the _NAVITEM
// paint arm). The bug it locks: before nav_item, a sidebar list used content-sized buttons that did NOT grow
// with a resized sidebar, leaving an odd gap. nav_item GROWS to fill the row, paints LEFT-aligned, and takes the
// accent fill when active. This builds a STRETCH sidebar (strut sbw | row[ nav_item | "..." ]) at TWO widths and
// tapes the painted commands: the nav `round` card must WIDEN with sbw (fill), the trailing "..." stays its own
// width on the right, and the active row uses the accent fill (a distinct colour). Text is left-aligned at x+pad.
import "std/draw" as draw
import "std/flare" as flare


fn row(mut f: flare.Flare, key: string, label: string, active: bool) {
    f.key(key)
    f.row(flare.START, flare.CENTER)
    if f.nav_item(label, active) {           // grow=1 → fills the row width
    }
    if f.ghost_button("...") {               // grow=0 → stays its own width, pinned right
    }
    f.end()
    f.key_clear()
}


fn sidebar(mut f: flare.Flare, sbw: int) {
    f.row_grow(flare.START, flare.STRETCH)
    f.panel_begin(flare.START, flare.STRETCH)   // STRETCH so each row fills the sidebar width
    f.strut(sbw, 0)
    row(f, "a", "Alpha", true)                  // active → accent fill
    row(f, "b", "Beta", false)                  // plain
    f.end()
    f.end()
}


fn main() -> int {
    draw.window(520, 240, "flarenavtest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_nav.tape")

    // Narrow sidebar (sbw=200): the nav cards fill ~200px wide.
    draw.begin(f.bg())
    f.begin()
    f.ui.mx = -1  f.ui.my = -1  f.ui.down = false  f.ui.was = false
    sidebar(f, 200)
    f.finish()
    draw.finish()
    print("narrow\n")

    // Wide sidebar (sbw=360): the same rows now fill ~360px — the nav cards must be WIDER (the fix).
    draw.begin(f.bg())
    f.begin()
    f.ui.mx = -1  f.ui.my = -1  f.ui.down = false  f.ui.was = false
    sidebar(f, 360)
    f.finish()
    draw.finish()
    print("wide\n")

    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_nav.tape"))
    return 0
}
