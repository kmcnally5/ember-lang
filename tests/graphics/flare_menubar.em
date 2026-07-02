// tests/graphics/flare_menubar.em — regression for std/flare's top menu bar (menubar_begin / menu /
// menu_item_accel / menu_sep / submenu). The bar FLOATS at (0,0) as a full-width strip (bar surface +
// a bottom hairline) on the base layer; an open menu drops a card on the modal layer (2000000), and a
// submenu opened from inside it stacks one layer higher (2000001) — the golden asserts that nesting.
//
// The open state is seeded directly (f.set_str at empty scope writes the bar's raw "__mb_open"/"__mb_sub"
// keys), so the frame is deterministic without a real click. Two warm-up frames settle the last-frame
// rects the menu/submenu anchor against; the third, taped frame is the settled one asserted here.
//
// NOTE (OFI-068): text x-positions/widths drift ±1px across freetype builds — re-bless per machine if
// needed; the bar strip, the layered menu cards, and the row text are the stable structure.
import "std/draw" as draw
import "std/flare" as flare


fn build(mut f: flare.Flare) {
    f.menubar_begin()
    if f.menu("File") {
        if f.menu_item_accel("New chat", "Cmd N") { }
        if f.menu_item_accel("Open…", "Cmd O") { }
        f.menu_sep()
        if f.submenu("Export") {
            if f.menu_item("Markdown") { }
            if f.menu_item("JSON") { }
            f.submenu_end()
        }
        f.menu_sep()
        if f.menu_item("Quit") { }
        f.menu_end()
    }
    if f.menu("Edit") {
        if f.menu_item("Undo") { }
        f.menu_end()
    }
    if f.menu("View") {
        if f.menu_item("Zoom In") { }
        f.menu_end()
    }
    f.menubar_end()
}


fn frame(mut f: flare.Flare) {
    draw.begin(f.bg())
    f.begin()
    f.set_str("__mb_open", "File")     // force the File menu (and its Export submenu) open, deterministically
    f.set_str("__mb_sub", "Export")
    build(f)
    f.finish()
    draw.finish()
}


fn main() -> int {
    draw.window(600, 360, "flaremenubartest")
    var f = flare.new()
    f.use_dark()
    var i = 0
    loop {
        if i == 2 {
            break
        }
        frame(f)                        // warm-up: settle the anchor rects
        i = i + 1
    }
    draw.tape_on("/tmp/ember_flare_menubar.tape")
    frame(f)                            // the settled frame — asserted
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_menubar.tape"))
    return 0
}
