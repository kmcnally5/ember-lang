// 21_flare_menubar.em — a top MENU BAR on Flare (MANIFESTO §5g). The window wears a real File / Edit /
// View / Help menu strip: click a title to drop its menu, and — once one is open — just slide across the
// bar to switch between them (the familiar menu-bar hover-follow). Rows carry keyboard-accelerator hints
// (menu_item_accel), separators group them (menu_sep), and a submenu (▸) nests a second menu to the right.
//
// The bar is a floating overlay that takes no layout space, so the body starts f.menubar_height() pixels
// down — the same pattern the Claude-desktop app uses to sit its dock under the menus.
//
//   make graphics && build/emberc-gfx --emit=run examples/graphics/21_flare_menubar.em

import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(640, 460, "Menu bar")
    var f = flare.new()
    f.use_dark()

    var dark = true
    var status = "Ready — open a menu from the bar."
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

        draw.begin(f.bg())
        f.begin()

        // ---- the menu bar (floats at the top; the body is inset below it) ----
        f.menubar_begin()
        if f.menu("File") {
            if f.menu_item_accel("New", "Cmd N") {
                count = count + 1
                status = "File ▸ New  (#{count})"
            }
            if f.menu_item_accel("Open…", "Cmd O") {
                status = "File ▸ Open…"
            }
            f.menu_sep()
            if f.submenu("Export as") {
                if f.menu_item("Markdown") {
                    status = "Exported as Markdown"
                }
                if f.menu_item("JSON") {
                    status = "Exported as JSON"
                }
                f.submenu_end()
            }
            f.menu_sep()
            if f.menu_item_accel("Quit", "Cmd Q") {
                status = "Quit (demo — window stays open)"
            }
            f.menu_end()
        }
        if f.menu("Edit") {
            if f.menu_item_accel("Undo", "Cmd Z") {
                status = "Edit ▸ Undo"
            }
            if f.menu_item_accel("Redo", "Cmd Y") {
                status = "Edit ▸ Redo"
            }
            f.menu_sep()
            if f.menu_item("Select All") {
                status = "Edit ▸ Select All"
            }
            f.menu_end()
        }
        if f.menu("View") {
            if f.menu_item("Toggle theme") {
                dark = !dark
                var name = "Light"
                if dark {
                    name = "Dark"
                }
                status = "Theme → " + name
            }
            f.menu_end()
        }
        if f.menu("Help") {
            if f.menu_item("About") {
                status = "A Flare menu-bar demo."
            }
            f.menu_end()
        }
        f.menubar_end()

        // ---- the body, inset below the bar ----
        f.strut(0, f.menubar_height())
        f.heading("Flare menu bar")
        f.text_muted(status)

        f.finish()
        draw.finish()
    }
    draw.close()
    return 0
}
