// tests/graphics/flare_button_size.em — regression for OFI-115: an atomic action widget sizes to its
// CONTENT, even inside the default stretch column, instead of spanning the whole window. A bare
// f.button paints a narrow pill at the left; f.button_fill (the opt-in) spans the column. The two
// pills' WIDTHS are the assertion — if a bare button regressed to stretching, its round op would be
// as wide as the fill one. One frame, no input injected.
//
// NOTE (OFI-068): text x-positions/widths drift ±1px across freetype builds — re-bless per machine if
// needed; the relative narrow-vs-wide pill shape is the stable signal.
import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(300, 200, "flarebuttonsizetest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_button_size.tape")
    var frame = 0
    loop {
        if frame == 1 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        let _ = f.button("OK")          // content-sized: a narrow pill at the left
        let _ = f.button_fill("OK")     // opt-in full width: spans the column
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_button_size.tape"))
    return 0
}
