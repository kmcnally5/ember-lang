// tests/graphics/wrap.em — regression for f.paragraph word-wrapping (std/flare). A long string is
// wrapped to a fixed pixel width; each wrapped line becomes a label leaf stacked tightly, so the tape
// records one draw_text per line at its position. Guards wrap()'s greedy line-breaking + the paragraph
// layout. (Line breaks depend on FreeType glyph widths, so this golden is font-version-sensitive, like
// the rest of the suite — OFI-068.)
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(640, 360, "wraptest")
    var f = flare.new()
    f.use_dark()
    draw.tape_on("/tmp/ember_wrap_test.tape")

    draw.begin(f.bg())
    f.begin()
    f.paragraph("The quick brown fox jumps over the lazy dog and then keeps running well past the edge of the column, so the greedy word wrap must break it into several tidy lines.", 360)
    f.finish()
    draw.finish()

    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_wrap_test.tape"))
    return 0
}
