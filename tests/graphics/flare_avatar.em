// tests/graphics/flare_avatar.em — regression for std/flare's chat presentation: f.avatar and f.bubble.
// The assistant turn = an accent rounded badge (f.avatar, a square sized to row_h, glyph centred) beside
// rich Markdown; the user turn = a rounded tinted bubble (f.bubble_begin/end, a card at radius st.radius+4
// drawn before its children). Two frames for a stable layout; no input injected.
//
// NOTE (OFI-068): text x-positions/widths drift ±1px across freetype builds, so re-bless per machine if
// needed — the badge/bubble shape ops (the accent round, the radius-14 card + stroke) are the stable part.
import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(420, 240, "flareavatartest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_avatar.tape")
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.row(flare.START, flare.START)
        f.avatar("*")
        f.strut(8, 0)
        f.column(flare.START, flare.START)
        f.text_muted("Claude")
        f.markdown("Hi with **bold**.", 300)
        f.end()
        f.end()
        f.bubble_begin()
        f.text_muted("You")
        f.paragraph("A user message.", 360)
        f.bubble_end()
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_avatar.tape"))
    return 0
}
