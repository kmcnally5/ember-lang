// 24_flare_typeahead.em — a SLASH-COMMAND typeahead on Flare (MANIFESTO §5g), the Claude-Code "/" move.
// Type "/" in the composer and a filtered command list pops ABOVE the field: keep typing to narrow it,
// ↑/↓ to move the highlight, Enter/Tab (or click) to RUN the selected command, Esc to dismiss. The
// typeahead does not gate the field — you type straight through it — and it swallows the Enter it accepts
// on, so the composer doesn't also "send". The caller owns the text: on an accepted index it runs the
// command and clears the field (f.clear_field()).
//
//   make graphics && build/emberc-gfx --emit=run examples/graphics/24_flare_typeahead.em

import "std/draw" as draw
import "std/flare" as flare
import "std/string" as sstr

fn commands() -> [string] {
    return ["clear", "theme", "hello", "help"]
}


fn main() -> int {
    draw.window(560, 460, "Slash commands")
    var f = flare.new()

    var dark = true
    var input = ""
    var status = "Type  /  in the composer for a command."
    var dismissed = ""

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

        f.column(flare.START, flare.STRETCH)
        f.heading("Composer")
        f.text_muted(status)
        f.spacer()

        input = f.text_area("composer", input)
        var handled = false
        if sstr.starts_with(input, "/") && !sstr.contains(input, " ") && input != dismissed {
            let pick = f.typeahead("slash", "composer", sstr.cp_slice(input, 1, input.char_count()), commands())
            if pick == 0 - 2 {
                dismissed = input
            } else if pick >= 0 {
                handled = true
                input = ""
                f.clear_field()
                if pick == 0 {
                    status = "Ran /clear."
                } else if pick == 1 {
                    dark = !dark
                    status = "Ran /theme."
                } else if pick == 2 {
                    status = "Hello from /hello!"
                } else if pick == 3 {
                    status = "Commands: /clear /theme /hello /help"
                }
            }
        } else {
            dismissed = ""
        }
        if f.submit() && !handled {
            if input.len() > 0 {
                status = "Sent: " + input
            }
            input = ""
        }
        f.end()

        f.finish()
        draw.finish()
    }
    draw.close()
    return 0
}
