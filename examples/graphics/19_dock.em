// examples/graphics/19_dock.em — a docked workspace built on Flare's DockTree (T4 of the docking
// campaign). Three panels are tiled by a split tree — an editor with a terminal stacked under it,
// and a sidebar alongside — each painted as a themed frame (soft shadow, rounded fill, hairline
// border, a title bar). The layout is ANIMATED: every panel's drawn rect springs toward its solved
// target (FLIP), so when the layout changes the panels slide to fill the space instead of snapping.
//
// Press C to close the terminal panel and watch the editor and sidebar flow into the freed space.
// Build + run:  make graphics && build/emberc-gfx --emit=run examples/graphics/19_dock.em
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(1100, 680, "Ember — Flare DockTree")
    var f = flare.new()

    var t = flare.dock_new()
    let editor = t.add_root("editor")
    let sidebar = t.split(editor, "sidebar", true, 0.74)   // editor | sidebar
    var terminal = t.split(editor, "terminal", false, 0.72) // editor / terminal
    var term_open = true

    loop {
        if draw.closing() {
            break
        }
        // C closes the terminal once; the sidebar + editor then spring to fill the space (FLIP).
        if term_open && draw.key(67) {
            let id = t.close(terminal)
            f.forget(id)
            term_open = false
        }
        draw.begin(f.ui.style.bg)
        f.dock(t, 20, 20, screen_width() - 40, screen_height() - 40)
        draw.finish()
    }

    draw.close()
    return 0
}
