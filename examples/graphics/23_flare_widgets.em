// 23_flare_widgets.em — Flare form controls (MANIFESTO §5g): a checkbox (pill toggle), a slider (drag the
// knob across a value range), and a dropdown (click to drop a popover list, pick to set + close). Each is
// the `value = f.widget(key, value)` idiom — feed the current value in, store the returned value back — so
// there is no reactive plumbing, just the loop's own vars.
//
//   make graphics && build/emberc-gfx --emit=run examples/graphics/23_flare_widgets.em

import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(460, 420, "Form controls")
    var f = flare.new()

    var dark = true
    var notify = false
    var zoom = 120
    var model = 0
    let models = ["Opus 4.8", "Sonnet 4.6", "Haiku 4.5"]

    loop {
        if draw.closing() {
            break
        }
        if dark {
            f.use_dark()
        } else {
            f.use_light()
        }

        draw.begin(f.bg())
        f.begin()

        f.page_begin(360)
        f.heading("Settings")
        f.strut(0, 6)

        dark = f.checkbox("dark", "Dark theme", dark)
        notify = f.checkbox("notify", "Desktop notifications", notify)

        f.strut(0, 10)
        f.text_muted("Text size — {zoom}%")
        zoom = f.slider("zoom", zoom, 60, 220)

        f.strut(0, 10)
        f.text_muted("Model")
        f.row(flare.START, flare.CENTER)
        model = f.dropdown("model", models, model)
        f.end()

        f.strut(0, 12)
        var note = ""
        if notify {
            note = "  ·  notifications on"
        }
        f.text_muted("Selected: " + models[model] + note)
        f.page_end()

        f.finish()
        draw.finish()
    }
    draw.close()
    return 0
}
