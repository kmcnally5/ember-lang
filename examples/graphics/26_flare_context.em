// 26_flare_context.em — RIGHT-CLICK context menus + hover TOOLTIPS on Flare (MANIFESTO §5g). Right-click
// anywhere to open a context menu at the cursor (built on the popover); hover a toolbar button and hold to
// see its tooltip. Right-clicking rests on the new `mouse_right_down()` graphics native surfaced through
// `f.right_click()` / `f.right_clicked()`; tooltips on `f.tooltip(text)` called right after a widget.
//
//   make graphics && build/emberc-gfx --emit=run examples/graphics/26_flare_context.em

import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(560, 380, "Context menu")
    var f = flare.new()

    var dark = true
    var status = "Right-click anywhere for a menu · hover a button for a tooltip."
    var menu_open = false
    var menu_x = 0
    var menu_y = 0

    loop {
        if draw.closing() {
            break
        }
        if dark {
            f.use_dark()
        } else {
            f.use_light()
        }

        // a right-click anywhere opens the context menu at the cursor
        if f.right_click() {
            menu_open = true
            menu_x = mouse_x()
            menu_y = mouse_y()
        }

        draw.begin(f.bg())
        f.begin()

        f.heading("Right-click / tooltips")
        f.text_muted(status)
        f.strut(0, 8)

        f.row(flare.START, flare.CENTER)
        if f.ghost_button("New") { status = "New (toolbar)." }
        f.tooltip("Create a new item")
        if f.ghost_button("Copy") { status = "Copied." }
        f.tooltip("Copy to clipboard")
        if f.ghost_button("Theme") { dark = !dark }
        f.tooltip("Toggle light / dark")
        f.end()

        // the context menu — a popover at the cursor; a press outside dismisses it
        if menu_open {
            if !f.popover_begin("ctx", menu_x, menu_y) {
                menu_open = false
            }
            if f.menu_item("New item") {
                status = "New item (menu)."
                menu_open = false
            }
            if f.menu_item("Duplicate") {
                status = "Duplicated."
                menu_open = false
            }
            f.menu_sep()
            if f.menu_item("Delete") {
                status = "Deleted."
                menu_open = false
            }
            f.popover_end()
        }

        f.finish()
        draw.finish()
    }
    draw.close()
    return 0
}
