// 08_graphics.em — Ember reaches the screen (MANIFESTO §5g). Build the graphics
// compiler and run this to see a window:
//
//   make graphics
//   build/emberc-gfx --emit=run examples/08_graphics.em
//
// This is the immediate-mode model: the loop body IS one frame. There is no retained
// widget tree and no callbacks — the square's position is just an ordinary `var` the
// loop owns, input is polled as plain values, and each frame is *described* by the
// Ember code while the native backend renders it. The same ownership rules that make
// the rest of Ember memory-safe apply here unchanged, because no graph-shaped UI
// state ever exists.

import "std/draw" as draw

fn main() -> int {
    draw.window(800, 600, "Ember — move the square")

    var x = 375
    var y = 275
    let speed = 5

    loop {
        if draw.closing() {
            break
        }

        // Input is polled and returned as values — no event handlers, no lifetimes.
        if draw.key(draw.RIGHT) { x = x + speed }
        if draw.key(draw.LEFT)  { x = x - speed }
        if draw.key(draw.DOWN)  { y = y + speed }
        if draw.key(draw.UP)    { y = y - speed }

        // Describe this frame; the native backend draws it.
        draw.begin(draw.DARKGRAY)
        draw.rect(x, y, 50, 50, draw.RED)
        draw.text("move the square with the arrow keys", 20, 20, 20, draw.WHITE)
        draw.finish()
    }

    draw.close()
    return 0
}
