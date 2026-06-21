// tests/graphics/flare_code_select.em — regression for SELECTABLE code blocks: a fenced code panel whose
// text can be highlighted with the mouse and copied (Ctrl/Cmd+C), the read-only counterpart to a text area
// (std/ui _code_input + std/flare _paint_code). Code blocks used to offer only a Copy button; now their text
// selects like every editor's. Input is injected (focus + buf + selection set directly, like text_field.em)
// so the tape is deterministic: with the first code block focused and its single line "x = 1" fully selected,
// a translucent accent highlight (op:"round", alpha:70) must be painted BEHIND the syntax-highlit glyphs.
// Two frames so the input-now/paint-later split (input runs against last frame's rect) is exercised too.
//
// NOTE (OFI-068): text x-positions/widths drift ±1px across freetype builds — re-bless per machine if needed.
import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(420, 320, "flarecodeselecttest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_code_select.tape")
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.ui.focus      = hash("_code0")   // inject: first code block focused (id == hash of its block key)
        f.ui.buf        = "x = 1"          // the focused block's source (what a press would have loaded)
        f.ui.sel_anchor = 0                // selection spans the whole line: [0, 5)
        f.ui.caret      = 5
        f.column(flare.START, flare.START)
        f.markdown("Selectable code:\n\n```python\nx = 1\n```", 320)
        f.end()
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_code_select.tape"))
    return 0
}
