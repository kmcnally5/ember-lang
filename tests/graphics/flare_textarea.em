// tests/graphics/flare_textarea.em — regression for the multi-line text_area (std/ui _ta_edit/_ta_draw +
// _wrap_lines, wrapped by std/flare). A value with a long WRAPPING line plus a hard newline renders as
// several visual lines; focusing it (state injected directly, like text_field.em) shows the accent ring and
// a 2D blinking caret. Input is injected so the tape is deterministic. Two frames so layout/auto-grow settle.
//
// NOTE (OFI-068): text x-positions/widths drift ±1px across freetype builds — re-bless per machine if needed.
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(320, 220, "flaretextareatest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_textarea.tape")
    let val = "the quick brown fox jumps over the lazy dog\nsecond line"
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.column(flare.START, flare.STRETCH)
        f.strut(300, 0)
        f.ui.focus = f.ui.wid("composer")    // inject focus + caret for a deterministic focused render
        f.ui.buf = val
        f.ui.caret = 4
        f.ui.sel_anchor = 4
        f.ui.frame = 0
        let _ = f.text_area("composer", val)
        f.end()
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_textarea.tape"))
    return 0
}
