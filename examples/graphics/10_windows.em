// 10_windows.em — overlapping, draggable, z-ordered windows (MANIFESTO §5g, Phase B).
// Build and run:  make graphics && build/emberc-gfx --emit=run examples/10_windows.em
//
// This is the immediate-mode payoff that's hardest for an ownership model: two windows
// that overlap, each holding live widgets, each draggable by its title bar, with clicks
// going only to the window on top. There is still NO retained widget tree — the windows
// are rebuilt every frame from plain `var` state. What persists across frames (each
// window's position and z-order) lives in the `Ui` registry, not in a graph of nodes.
//
// Drag a title bar to move a window. Click a window to bring it to the front. The
// counter and the toggle belong to different windows and never interfere.

import "std/draw" as draw
import "std/ui" as ui

fn main() -> int {
    draw.window(640, 480, "Ember — overlapping windows")

    var count = 0
    var lit   = true
    var u = ui.new()

    loop {
        if draw.closing() {
            break
        }
        draw.begin(u.style.bg)
        u.begin()

        u.label("Drag a title bar to move a window; click one to raise it.")

        if u.window_begin("Counter") {
            u.label("count = {count}")
            if u.button("increment") {
                count = count + 1
            }
            u.same_line()
            if u.button("reset") {
                count = 0
            }
        }
        u.window_end()

        if u.window_begin("Toggle") {
            lit = u.checkbox("light on", lit)
            if lit {
                u.label("the light is ON")
            } else {
                u.label("the light is OFF")
            }
        }
        u.window_end()

        u.end()
        draw.finish()
    }

    draw.close()
    return 0
}
