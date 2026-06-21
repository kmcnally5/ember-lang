// tests/graphics/tape.em — regression test for the UI tape (MANIFESTO §5c).
// Records a press-then-release click on a button to a file, then reads the tape back
// and prints it so the golden locks the exact frame records + interaction event.
//
// Note: the per-frame "mouse" is polled from the backend (0,0 headless); the click is
// driven by injected Ui input, which is what std/ui's logic — and thus the event — sees.
// In a real run the polled mouse and the logic agree.

import "std/draw" as draw
import "std/ui" as ui

fn main() -> int {
    draw.window(200, 120, "tapetest")
    var u = ui.new()
    draw.tape_on("/tmp/ember_tape_test.tape")

    // Frame 1: press on the button (it becomes active, not yet a click).
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 20  u.my = 20  u.down = true  u.was = false
    u.button("Go")
    u.end()
    draw.finish()

    // Frame 2: release over the button -> a click, recorded as an event.
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 20  u.my = 20  u.down = false  u.was = true
    u.button("Go")
    u.end()
    draw.finish()

    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_tape_test.tape"))
    return 0
}
