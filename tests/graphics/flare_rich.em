// tests/graphics/flare_rich.em — regression for std/flare's inline rich text (f.markdown → rich_text).
// **bold** is faux-bold (the word drawn twice, 1px apart); `code` sits on a chip (a round drawn just
// before the monospace text); a [link](url) draws in the accent colour with a 1px underline round; a
// "# heading" renders larger and faux-bold. Crucially, the markers must NOT leak through as literal text.
// Two frames for a stable layout; no input injected.
//
// NOTE (OFI-068): text x-positions/widths shift ±1px with the freetype build, so this golden may need
// re-blessing on another machine (`tests/run-graphics.sh --update`), like its sibling flare.em — the
// shape ops (the code chip, link underline, faux-bold double-draws) are the stable part being asserted.
import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(520, 240, "flarerichtest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_rich.tape")
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.markdown("# Title\nA **bold** word, a `code` span, and a [link](http://x).", 440)
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_rich.tape"))
    return 0
}
