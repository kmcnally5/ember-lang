// tests/graphics/flare_flip.em — regression for f.animate_layout (FLIP). The watched widget sits at the top;
// on frame index 2 an INVISIBLE 60px spacer appears above it, so its SOLVED position jumps down. FLIP must NOT
// teleport it: it springs from the old position toward the new over the fixed timestep, settling exactly at the
// new spot (no drift). We read the widget's painted Y straight from the rects cache each frame — finish() stores
// the OFFSET (animated) rect there — so the golden is a compact, font-independent curve: flat at the top, then
// a smooth ease down to the settled position.
import "std/draw" as draw
import "std/flare" as flare

fn body(mut f: flare.Flare, pushed: bool) {
    f.column(flare.START, flare.START)
    if pushed {
        f.strut(0, 60)                 // an invisible spacer: pushes the watched widget down, paints nothing
    }
    f.animate_layout("w")
    if f.button("W") {
    }
    f.end_animate_layout()
    f.end()
}

fn main() -> int {
    draw.window(400, 260, "flarefliptest")
    var f = flare.new()
    var fr = 0
    loop {
        if fr == 40 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.ui.mx = -1  f.ui.my = -1  f.ui.down = false  f.ui.was = false
        body(f, fr >= 2)
        f.finish()
        draw.finish()
        match f.rects.get("W") {
            case Some(r) { print("f{fr} y={r.y}\n") }
            case None { print("f{fr} y=?\n") }
        }
        fr = fr + 1
    }
    draw.close()
    return 0
}
