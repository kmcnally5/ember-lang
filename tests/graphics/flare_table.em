// tests/graphics/flare_table.em — regression for Markdown TABLE rendering (std/markdown's Table block +
// std/flare._table). A "| a | b |" table with a "|---|" separator becomes an aligned grid: columns sized to
// their widest cell, the header row faux-bold with a hairline rule beneath, body rows below — and NO raw
// pipes leaking as text. Two frames; no input injected.
//
// NOTE (OFI-068): text x-positions/widths drift ±1px across freetype builds — re-bless per machine if needed.
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(420, 240, "flaretabletest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_table.tape")
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.markdown("| Model | Speed |\n| --- | --- |\n| Opus | slow |\n| Haiku | fast |", 380)
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_table.tape"))
    return 0
}
