// tests/graphics/flare_nav_ellipsis.em — regression for nav_item's ellipsis-to-WIDTH: the label trims to its
// pill's painted pixel width (binary-searched in _fit_text), with a 1-frame lag like text_area's auto-grow. A
// long title is shown at a NARROW sidebar then a WIDE one; the tape proves the displayed label trims MORE when
// narrow and LESS when wide — text FILLS the pill instead of a fixed char cap. Font-dependent like the other
// text goldens (recalibrate with --update if the bundled font's metrics shift).
import "std/draw" as draw
import "std/flare" as flare

fn side(mut f: flare.Flare, sbw: int) {
    f.row_grow(flare.START, flare.STRETCH)
    f.panel_begin(flare.START, flare.STRETCH)
    f.strut(sbw, 0)
    f.key("a")
    if f.nav_item("Explain a tricky concept simply and clearly", false) {
    }
    f.key_clear()
    f.end()
    f.end()
}

fn main() -> int {
    draw.window(620, 160, "flarenavelltest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_nav_ell.tape")
    var fr = 0
    loop {
        if fr == 4 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.ui.mx = -1  f.ui.my = -1  f.ui.down = false  f.ui.was = false
        var sbw = 220
        if fr >= 2 {
            sbw = 480
        }
        side(f, sbw)
        f.finish()
        draw.finish()
        print("f{fr}\n")
        fr = fr + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_nav_ell.tape"))
    return 0
}
