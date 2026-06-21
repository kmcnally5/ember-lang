// tests/graphics/text_field.em — regression for text_field horizontal scroll (OFI-055). A value
// wider than the field is CLIPPED to the field (clip rect in the tape), and when the field is
// focused with the caret past the right edge the text SCROLLS left (negative draw_text x offset)
// so the caret stays inside. Input is injected (focus/buf/caret set directly, like scroll.em) so
// the tape — clip rect, shifted text x, caret rect — is deterministic.
import "std/draw" as draw
import "std/ui" as ui
import "std/string" as str

fn field(mut u: ui.Ui, val: string) {
    let _ = u.text_field("f", val)
}

fn main() -> int {
    draw.window(300, 120, "textfieldtest")
    var u = ui.new()
    draw.tape_on("/tmp/ember_textfield_test.tape")

    let wide = "the quick brown fox jumps over the lazy dog"   // far wider than the 240px field

    // Frame 1: UNFOCUSED — the wide value is clipped to the field and shown from the start (no scroll).
    draw.begin(u.style.bg)
    u.begin()
    u.mx = -1  u.my = -1  u.down = false  u.was = false
    field(u, wide)
    u.end()
    draw.finish()

    // Frame 2: FOCUSED with the caret at the END — the text scrolls left so the caret stays visible.
    draw.begin(u.style.bg)
    u.begin()
    u.mx = -1  u.my = -1  u.down = false  u.was = false
    u.focus    = u.wid("f")          // inject focus on the field (its id == hash of the key)
    u.buf      = wide
    u.caret    = str.cp_count(wide)  // caret at the very end
    u.text_off = 0                   // start unscrolled; the field computes the scroll this frame
    u.frame    = 0                   // frame 0 → caret blink ON, so the caret rect is in the tape
    field(u, wide)
    u.end()
    draw.finish()

    // Frame 3: FOCUSED with a SELECTION (code points 4..20) — a translucent accent highlight is drawn
    // behind that run (a fill_round with alpha) before the text, plus the caret at the selection end.
    draw.begin(u.style.bg)
    u.begin()
    u.mx = -1  u.my = -1  u.down = false  u.was = false
    u.focus      = u.wid("f")
    u.buf        = wide
    u.sel_anchor = 4                 // "quick brown fox" is selected (cp 4..20)
    u.caret      = 20
    u.text_off   = 0
    u.frame      = 0
    field(u, wide)
    u.end()
    draw.finish()

    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_textfield_test.tape"))
    return 0
}
