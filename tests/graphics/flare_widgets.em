// tests/graphics/flare_widgets.em — regression for std/flare's form controls: checkbox (a pill toggle +
// label), slider (a value track + knob over an int range), and dropdown (a collapsed selector box that
// drops a popover list). Asserts: an ON checkbox (accent pill, knob right) and an OFF one (track, knob
// left); a slider at 140 in [60,220] → a half-filled track (accent w = half of 200) with the knob at the
// midpoint; and a dropdown showing the selected option + "▾", with its list forced open (layer 2000000)
// listing all options. The dropdown-open state is seeded via set_str; warm-up frames settle the anchor.
//
// NOTE (OFI-068): text x/width drift ±1px across freetype builds — re-bless per machine if needed; the
// pills, track+fill, the selector box, and the popover list are the stable structure.
import "std/draw" as draw
import "std/flare" as flare


fn body(mut f: flare.Flare) {
    f.column(flare.START, flare.START)
    let _a = f.checkbox("dark", "Dark mode", true)
    let _b = f.checkbox("beta", "Beta features", false)
    f.strut(0, 8)
    let _z = f.slider("zoom", 140, 60, 220)
    f.strut(0, 8)
    let _m = f.dropdown("model", ["Opus 4.8", "Sonnet 4.6", "Haiku 4.5"], 1)
    f.end()
}


fn main() -> int {
    draw.window(420, 360, "flarewidgetstest")
    var f = flare.new()
    f.use_dark()
    var i = 0
    loop {
        if i == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.set_str("dd/model.open", "1")     // force the dropdown list open, deterministically
        body(f)
        f.finish()
        draw.finish()
        i = i + 1
    }
    draw.tape_on("/tmp/ember_flare_widgets.tape")
    draw.begin(f.bg())
    f.begin()
    f.set_str("dd/model.open", "1")
    body(f)
    f.finish()
    draw.finish()
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_widgets.tape"))
    return 0
}
