// 17_flare.em — std/flare: declarative, component-style UI with a REAL flexbox layout engine and a
// warm, Claude-inspired house look (MANIFESTO §5g). Build the graphics compiler and run:
//
//   make graphics && EMBER_STD=./std build/emberc-gfx --emit=run examples/17_flare.em
//
// Notice: components are functions, events are RETURN VALUES (`if f.primary("Compose") {…}`), and
// layout is flexbox — `row`/`column` with `justify` (main axis) and `align` (cross axis), `spacer()`
// to push to an edge, all solved each frame by std/layout and painted in the house theme.

import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(580, 400, "Flare")
    var f = flare.new()
    var count = 0
    var dark = false

    loop {
        if draw.closing() {
            break
        }
        draw.begin(f.bg())
        f.begin()

        // Toolbar: title on the left, actions pushed right by a flexible spacer.
        f.row(flare.BETWEEN, flare.CENTER)
        f.heading("Flare")
        f.spacer()
        if f.button("Theme") {
            dark = !dark
            if dark {
                f.use_dark()
            } else {
                f.use_light()
            }
        }
        if f.primary("Compose") {
            count = count + 1
        }
        f.end()

        // Body: a centred title (heading in the STRETCH column) and copy.
        f.heading("Real flexbox, Claude style")
        f.label("Layout solved by std/layout; painted in the warm house theme.")
        f.text_muted("Composed {count} times.")

        // A centred row of secondary actions.
        f.row(flare.CENTER, flare.CENTER)
        if f.button("One") {
            count = count + 1
        }
        if f.button("Two") {
            count = count + 1
        }
        if f.button("Three") {
            count = count + 1
        }
        f.end()

        f.finish()
        draw.finish()
    }

    draw.close()
    return 0
}
