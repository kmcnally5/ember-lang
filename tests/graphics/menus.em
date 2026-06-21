// tests/graphics/menus.em — regression test for std/ui dropdown menus (Phase B3).
// Injects input state (no real mouse) and asserts open/close, item selection, and that
// an open menu is modal. Run via `make test-graphics`. Output is deterministic.

import "std/draw" as draw
import "std/ui" as ui

fn main() -> int {
    draw.window(400, 300, "menutest")
    var u = ui.new()
    let fileid = hash("File")

    // Frame 1: no input — the menu is closed.
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 0  u.my = 0  u.down = false  u.was = false
    let f1 = u.menu_begin("File")
    if f1 {
        u.menu_item("Open")  u.menu_item("Save")
    }
    u.menu_end()
    draw.finish()
    var open1 = 0
    if f1 {
        open1 = 1
    }
    println("frame1 open={open1} popup={u.open_popup}")

    // Frame 2: a press on the header opens the menu.
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 10  u.my = 10  u.down = true  u.was = false
    let f2 = u.menu_begin("File")
    if f2 {
        u.menu_item("Open")  u.menu_item("Save")
    }
    u.menu_end()
    draw.finish()
    var open2 = 0
    if f2 {
        open2 = 1
    }
    var isfile = 0
    if u.open_popup == fileid {
        isfile = 1
    }
    println("frame2 open={open2} is_file_open={isfile}")

    // Frame 3: a press on the "Open" item selects it and closes the menu.
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 20  u.my = 50  u.down = true  u.was = false
    var chose = 0
    if u.menu_begin("File") {
        if u.menu_item("Open") {
            chose = 1
        }
        u.menu_item("Save")
    }
    u.menu_end()
    draw.finish()
    var closed = 0
    if u.open_popup == -1 {     // ui.NONE
        closed = 1
    }
    println("frame3 chose_open={chose} closed_after={closed}")

    // Modal: while a menu is open, ordinary widgets are inert.
    u.open_popup = fileid
    u.mx = 50  u.my = 50  u.down = true  u.was = false  u.active = -1
    u.press(7, 40, 40, 40, 40)
    var blocked = 0
    if u.active == -1 {
        blocked = 1
    }
    println("modal_blocks_widgets={blocked}")

    draw.close()
    return 0
}
