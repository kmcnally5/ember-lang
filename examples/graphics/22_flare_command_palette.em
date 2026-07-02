// 22_flare_command_palette.em — a ⌘K COMMAND PALETTE on Flare (MANIFESTO §5g). Press ⌘K (or Ctrl+K) to
// open a centred launcher: type to fuzzy-filter the command list, ↑/↓ to move the highlight, Enter to run
// the selected command, Esc (or a click on the dimmed scrim) to dismiss. The palette is a single
// self-contained call — it owns its query + selection and auto-focuses so you can type immediately.
//
//   make graphics && build/emberc-gfx --emit=run examples/graphics/22_flare_command_palette.em

import "std/draw" as draw
import "std/flare" as flare

let KEY_SUPER_L = 343
let KEY_SUPER_R = 347
let KEY_CTRL_L  = 341
let KEY_K       = 75


fn commands() -> [string] {
    return ["New item", "Toggle theme", "Zoom in", "Zoom out", "Reset zoom", "Say hello"]
}


fn main() -> int {
    draw.window(680, 480, "Command palette")
    var f = flare.new()
    f.use_dark()

    var dark = true
    var open = false
    var status = "Press  ⌘K  (or Ctrl+K) to open the command palette."
    var count = 0

    loop {
        if draw.closing() {
            break
        }
        if dark {
            f.use_dark()
        } else {
            f.use_light()
        }

        let cmd = key_down(KEY_SUPER_L) || key_down(KEY_SUPER_R) || key_down(KEY_CTRL_L)
        if cmd && key_pressed(KEY_K) {
            open = true
        }

        draw.begin(f.bg())
        f.begin()

        f.heading("Command palette demo")
        f.text_muted(status)
        f.text_muted("Items created: {count}")

        if open {
            let pick = f.command_palette("cmdk", commands())
            if pick != 0 - 1 {                  // -1 = still open; anything else closes it
                open = false
                if pick == 0 {
                    count = count + 1
                    status = "New item created (#{count})."
                } else if pick == 1 {
                    dark = !dark
                    var name = "Light"
                    if dark {
                        name = "Dark"
                    }
                    status = "Theme → " + name
                } else if pick == 2 {
                    f.zoom_by(10)
                    status = "Zoomed in."
                } else if pick == 3 {
                    f.zoom_by(0 - 10)
                    status = "Zoomed out."
                } else if pick == 4 {
                    f.set_zoom(100)
                    status = "Zoom reset to 100%."
                } else if pick == 5 {
                    status = "Hello from the command palette!"
                }
            }
        }

        f.finish()
        draw.finish()
    }
    draw.close()
    return 0
}
