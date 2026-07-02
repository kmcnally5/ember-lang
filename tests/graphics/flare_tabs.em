// tests/graphics/flare_tabs.em — regression for std/flare's tabs(): a horizontal strip of closeable tab
// chips (browser / editor style). The active chip is raised to the panel colour with an accent underline;
// the rest are the bar colour, muted. Each chip carries a trailing "×" close zone. tabs() returns a
// TabResult (active / closed / moved_from / moved_to); this test asserts the static render of four tabs with
// the second active — the chip fills, the labels, the "×" glyphs, and the accent underline under "lexer.c".
//
// NOTE (OFI-068): text x/width drift ±1px across freetype builds — re-bless per machine if needed; the chip
// fills, the "×" close glyphs, and the active underline are the stable structure.
import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(520, 200, "flaretabstest")
    var labels = ["main.em", "lexer.c", "parser.c", "README"]
    var active = 1
    var f = flare.new()
    f.use_dark()
    var i = 0
    loop {
        if i == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.row(flare.START, flare.CENTER)
        let _r = f.tabs("files", labels, active)
        f.end()
        f.finish()
        draw.finish()
        i = i + 1
    }
    draw.tape_on("/tmp/ember_flare_tabs.tape")
    draw.begin(f.bg())
    f.begin()
    f.row(flare.START, flare.CENTER)
    let _r = f.tabs("files", labels, active)
    f.end()
    f.finish()
    draw.finish()
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_tabs.tape"))
    return 0
}
