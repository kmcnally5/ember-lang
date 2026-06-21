// 09_ui.em — immediate-mode widgets (MANIFESTO §5g). Build the graphics compiler and
// run it to interact:  make graphics && build/emberc-gfx --emit=run examples/09_ui.em
//
// The UI is a pure function of state, rebuilt every frame. There is no widget tree
// and no callbacks: `count`, `vol`, `muted` are plain `var`s the loop owns, and each
// widget reports its interaction as a value (`if u.button(...) { ... }`). The `Ui`
// context `u` is threaded through the loop, carrying only the layout cursor, this
// frame's input, and which widget is hovered/pressed. The look is modern: rounded,
// softly-shadowed, gradient-lit widgets that lighten on hover — all driven by the
// theme `Style`, so `ui.dark()` / `ui.light()` reskin everything at once.

import "std/draw" as draw
import "std/ui" as ui

fn main() -> int {
    draw.window(440, 460, "Ember — immediate-mode UI")

    var count = 0
    var vol   = 50
    var muted = false
    var dark  = true
    var name  = "Ember"
    var u = ui.new()

    loop {
        if draw.closing() {
            break
        }
        draw.begin(u.style.bg)          // the theme's background colour
        u.begin()

        u.heading("Control Panel", 408) // centre-justified title

        u.label("Counter")
        u.indent()                      // group the controls under the heading
        if u.button("increment") {      // two buttons on one row via same_line
            count = count + 1
        }
        u.same_line()
        if u.button("decrement") {
            count = count - 1
        }
        u.label("count = {count}")
        u.unindent()

        u.spacing(12)
        u.label("Audio")
        u.indent()
        muted = u.checkbox("muted", muted)    // an iOS-style toggle
        vol = u.slider("volume", vol, 0, 100) // pill track + shadowed knob
        u.label("volume = {vol}")
        u.unindent()

        u.spacing(12)
        name = u.text_field("name", name)     // click to focus, then type
        u.label("hello, {name}")

        u.spacing(12)
        u.label("History (scrolls)")
        u.scroll_begin(408, 120)              // a clipped, scrollable region
        var i = 0
        loop {
            if i >= count { break }
            u.label("tick {i}")
            u.label_right("#{i}", 388)        // right-justified value
            i = i + 1
        }
        u.scroll_end()

        if u.button("toggle theme") {   // swap the whole theme — every widget follows
            dark = !dark
            if dark {
                u.style = ui.dark()
            } else {
                u.style = ui.light()
            }
        }

        u.end()
        draw.finish()
    }

    draw.close()
    return 0
}
