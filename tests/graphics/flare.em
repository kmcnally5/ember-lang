// tests/graphics/flare.em — regression for std/flare's flexbox layout integration + the id-scope.
// Renders a centred heading and two keyed counters (each a row of "-" / label / "+"). Locks the
// SOLVED layout positions and the warm Claude render via the tape, and the id-scope keeps the two
// counters' identical "-"/"+" buttons distinct (distinct solved rects, distinct ids). Two frames so
// the layout is stable; no input injected (the click path reuses std/ui's press, covered elsewhere).

import "std/draw" as draw
import "std/flare" as flare


fn Counter(mut f: flare.Flare, key: string, title: string) {
    f.key(key)
    var n = f.state_int("n", 0)
    f.row(flare.START, flare.CENTER)
    if f.button("-") {
        n = n - 1
    }
    f.label("{title}={n}")
    if f.button("+") {
        n = n + 1
    }
    f.end()
    f.set_int("n", n)
    f.key_clear()
}


fn main() -> int {
    draw.window(300, 180, "flaretest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_test.tape")
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.heading("Counters")
        Counter(f, "a", "A")
        Counter(f, "b", "B")
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_test.tape"))
    return 0
}
