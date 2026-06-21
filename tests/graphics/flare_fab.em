// tests/graphics/flare_fab.em — regression for std/flare's scroll_fab: a round "jump to latest" button at
// the bottom-right of a scroll area, shown only when it's scrolled UP (content below the fold). The tall
// content here overflows the viewport, so once the overflow is known (2nd frame on) the FAB draws — a
// filled circle + "↓" on a high layer (MODAL_LAYER-1). Three frames; no input injected.
//
// NOTE (OFI-068): text x-positions/widths drift ±1px across freetype builds — re-bless per machine if
// needed; the FAB's circle + arrow are the stable shape ops being asserted.
import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(300, 200, "flarefabtest")
    var f = flare.new()
    var jumped = false
    draw.tape_on("/tmp/ember_flare_fab.tape")
    var frame = 0
    loop {
        if frame == 3 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.scroll_begin("sc")
        var i = 0
        loop {
            if i == 40 {
                break
            }
            f.label("line {i}")
            i = i + 1
        }
        f.scroll_end("sc")
        if f.scroll_fab("sc") {
            jumped = true
        }
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    if jumped {
        print("jumped")
    }
    print(read_file("/tmp/ember_flare_fab.tape"))
    return 0
}
