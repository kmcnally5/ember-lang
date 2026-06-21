// 11_menus.em — dropdown menus and tooltips (MANIFESTO §5g, Phase B3).
// Build and run:  make graphics && build/emberc-gfx --emit=run examples/11_menus.em
//
// A menu is a modal, top-layer transient: click a header to open it, click an item to
// choose, click anywhere else to dismiss. As with every other widget there is no
// retained tree and no callbacks — `menu_item` simply returns true on the frame it is
// chosen, and the action is plain Ember code. Two menu headers sit side by side via
// same_line to form a menu bar. The button below carries a hover tooltip.

import "std/draw" as draw
import "std/ui" as ui

fn main() -> int {
    draw.window(520, 360, "Ember — menus & tooltips")

    var status = "ready"
    var u = ui.new()

    // Record a UI tape: one JSON line per frame (input + every draw command) plus
    // click/toggle/focus/menu events. Inspect menus.tape afterwards, or hand it to an
    // LLM to debug what the UI did. Recording is off unless a tape is open.
    draw.tape_on("menus.tape")

    loop {
        if draw.closing() {
            break
        }
        draw.begin(u.style.bg)
        u.begin()

        // --- menu bar: File and Edit, side by side ---
        if u.menu_begin("File") {
            if u.menu_item("New") {
                status = "File > New"
            }
            if u.menu_item("Open") {
                status = "File > Open"
            }
            if u.menu_item("Save") {
                status = "File > Save"
            }
        }
        u.menu_end()
        u.same_line()
        if u.menu_begin("Edit") {
            if u.menu_item("Copy") {
                status = "Edit > Copy"
            }
            if u.menu_item("Paste") {
                status = "Edit > Paste"
            }
        }
        u.menu_end()

        u.label("last action: {status}")

        // --- a button with a hover tooltip ---
        if u.button("Hover me") {
            status = "button clicked"
        }
        if u.hovered("Hover me") {
            u.tooltip("This is a tooltip")
        }

        u.end()
        draw.finish()
    }

    draw.tape_off()
    draw.close()
    return 0
}
