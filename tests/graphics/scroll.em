// tests/graphics/scroll.em — regression for scroll regions (MANIFESTO §5g). A list taller than
// its viewport is clipped and gains a scrollbar; the scroll offset shifts the content. Input is
// injected (the offset is set directly) so the tape — clip rect, clipped text positions, and the
// track+thumb — is deterministic.
import "std/draw" as draw
import "std/ui" as ui

fn list(mut u: ui.Ui) {
    u.heading("Items", 180)
    u.scroll_begin(180, 80)
    var i = 0
    loop {
        if i >= 8 { break }
        u.label("item {i}")
        i = i + 1
    }
    u.scroll_end()
}


fn main() -> int {
    draw.window(220, 200, "scrolltest")
    var u = ui.new()
    draw.tape_on("/tmp/ember_scroll_test.tape")

    // Frame 1: top of the list (offset 0) — establishes sc_max for the next frame.
    draw.begin(u.style.bg)
    u.begin()
    u.mx = -1  u.my = -1  u.down = false  u.was = false
    list(u)
    u.end()
    draw.finish()

    // Frame 2: scrolled down — content shifts up, thumb moves down.
    draw.begin(u.style.bg)
    u.begin()
    u.mx = -1  u.my = -1  u.down = false  u.was = false
    u.sc_off = 40
    list(u)
    u.end()
    draw.finish()

    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_scroll_test.tape"))
    return 0
}
