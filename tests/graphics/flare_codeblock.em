// tests/graphics/flare_codeblock.em — regression for a fenced code block + rich prose rendered inside a
// START-aligned column (the chat-turn layout beside an avatar). The code panel once collapsed to ZERO width
// because _code_block (and _quote_block) relied on STRETCH alignment, which the avatar column doesn't give
// (OFI-078) — so they now take an explicit width. Also guards inline-run SPACING around **bold** (each run
// measured exactly + the true in-context space as the gap). Asserts the code panel/clip have real width and
// the syntax-highlit source draws. Two frames; no input.
//
// NOTE (OFI-068): text x-positions/widths drift ±1px across freetype builds — re-bless per machine if needed.
import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(420, 320, "flarecodeblocktest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_codeblock.tape")
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.column(flare.START, flare.START)
        f.markdown("A **bold** word then code:\n\n```python\nx = 1\n```", 320)
        f.end()
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_codeblock.tape"))
    return 0
}
