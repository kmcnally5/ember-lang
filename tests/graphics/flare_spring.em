// tests/graphics/flare_spring.em — regression for f.spring + f.at. The spring eases toward its target over a
// FIXED timestep (SPRING_DT), so it is a pure function of FRAME COUNT — deterministic and replayable. It snaps
// to target on first sight (frame 0 = -200), then eases to 0 and SETTLES at rest (stops churning). Printing
// to_int(spring) each frame is a font-independent golden that locks the exact curve; f.at exercises the
// paint-offset path. No tape, no text metrics → immune to the OFI-068 font drift the other flare goldens carry.
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(400, 200, "flarespringtest")
    var f = flare.new()
    var fr = 0
    loop {
        if fr == 42 { break }
        draw.begin(f.bg())
        f.begin()
        f.ui.mx = -1  f.ui.my = -1  f.ui.down = false  f.ui.was = false
        var target = 0.0
        if fr == 0 { target = 0.0 - 200.0 }
        let x = f.spring("s", target)
        f.at(x, 0.0)
        f.label("x")
        f.end_at()
        f.finish()
        draw.finish()
        print("f{fr} x={to_int(x)}\n")
        fr = fr + 1
    }
    draw.close()
    return 0
}
