// tests/graphics/flare_sticky.em — regression for scroll_begin_sticky (chat-style stick-to-bottom). Tall
// content in a sticky viewport pins to the BOTTOM: the last item is visible and the first is scrolled above
// (a large negative y), NOT blank. Guards the bug where the 1e6 sentinel offset, used UNCLAMPED as the shift,
// pushed everything off-screen — finish() now clamps the shift to the real overflow. Three frames so the
// overflow settles. (Vertical scroll is row-height-based, so this is largely font-metric independent.)
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(220, 150, "flarestickytest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_sticky.tape")
    var frame = 0
    loop {
        if frame == 3 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.scroll_begin_sticky("sc")
        var i = 0
        loop {
            if i == 20 {
                break
            }
            f.label("line {i}")
            i = i + 1
        }
        f.scroll_end("sc")
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_sticky.tape"))
    return 0
}
