// tests/graphics/flare_tooltip.em — regression for std/flare's tooltip(): a small hint near the cursor after
// the most-recently-drawn widget has been hovered for a short dwell (~24 frames). Headless has no real cursor,
// so the test force-hovers the button each frame (f.ui.hot = f._last_wid) to run the dwell timer; by the taped
// frame the timer has elapsed and the tip card (a raised popover-style card on layer 2000000) + its text show.
//
// NOTE (OFI-068): text x/width drift ±1px across freetype builds — re-bless per machine if needed; the tip
// card and its text are the stable structure.
import "std/draw" as draw
import "std/flare" as flare


fn frame(mut f: flare.Flare) {
    draw.begin(f.bg())
    f.begin()
    f.row(flare.START, flare.CENTER)
    let _b = f.ghost_button("Copy")
    f.ui.hot = f._last_wid          // force-hover so the dwell timer advances without a real cursor
    f.tooltip("Copy to clipboard")
    f.end()
    f.finish()
    draw.finish()
}


fn main() -> int {
    draw.window(360, 220, "flaretooltiptest")
    var f = flare.new()
    f.use_dark()
    var i = 0
    loop {
        if i == 30 {
            break
        }
        frame(f)
        i = i + 1
    }
    draw.tape_on("/tmp/ember_flare_tooltip.tape")
    frame(f)
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_tooltip.tape"))
    return 0
}
