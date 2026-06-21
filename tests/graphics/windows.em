// tests/graphics/windows.em — regression test for the std/ui window system (Phase B).
// Graphics programs need a display, so this runs out of the default suite via
// `make test-graphics` (which builds/uses build/emberc-gfx). It does NOT rely on real
// mouse input: it injects input state directly onto the Ui and asserts the pure logic
// of registration, z-order focus, title-bar drag, and topmost-only input routing.
//
// Output is deterministic and compared against tests/graphics/windows.out.

import "std/draw" as draw
import "std/ui" as ui


// win pulls a window's persistent record out of the Ui's registry by title — the toolkit
// keys it by window id (hash of the title), so the test asserts against it the same way.
// `var r = w` deep-copies the value-struct out of the borrowed map read (OFI-064 fix), so the
// owned copy can be returned (a borrowed binding can't escape the function directly).
fn win(mut u: ui.Ui, title: string) -> ui.Window {
    let id = u.wid(title)
    var r = ui.Window { x: 0, y: 0, w: 0, h: 0, z: 0 }
    match u.wins.get(id) {
        case Some(w) { r = w }
        case None {}
    }
    return r
}


fn main() -> int {
    draw.window(500, 400, "wintest")
    var u = ui.new()

    // Frame 1: three windows register and cascade to distinct positions and z-order.
    // "Body" holds one label; the others are empty. window_end auto-sizes each to fit.
    draw.begin(u.style.bg)
    u.begin()
    u.window_begin("Alpha")  u.window_end()
    u.window_begin("Beta")   u.window_end()
    if u.window_begin("Body") {
        u.label("hi")
    }
    u.window_end()
    draw.finish()
    let reg = u.wins.size()
    let alpha = win(u, "Alpha")
    let beta = win(u, "Beta")
    let body = win(u, "Body")
    println("registered={reg} alpha_z={alpha.z} beta_z={beta.z}")

    // Auto-size: an empty window collapses to its title bar; a one-label window fits one row.
    let empty_h = u.style.row_h + u.style.pad + u.style.pad
    let one_h   = u.style.row_h + u.style.pad + u.style.row_h + u.style.pad
    println("alpha_h={alpha.h} (empty fit={empty_h}) body_h={body.h} (one-row fit={one_h})")
    if alpha.h == empty_h && body.h == one_h {
        println("PASS: windows auto-sized to their content")
    }

    let beta_id = u.wid("Beta")

    // Frame 2: a fresh press on Beta's title bar raises it and starts a drag.
    let beta1 = win(u, "Beta")
    draw.begin(u.style.bg)
    u.begin()
    u.hover_win = beta_id
    u.down = true
    u.was  = false
    u.mx   = beta1.x + 10
    u.my   = beta1.y + 5
    u.window_begin("Beta")  u.window_end()
    draw.finish()
    let alpha2 = win(u, "Alpha")
    let beta2  = win(u, "Beta")
    var raised = 0
    if beta2.z > alpha2.z {
        raised = 1
    }
    var dragging = 0
    if u.drag_id == beta_id {
        dragging = 1
    }
    println("raised={raised} dragging={dragging}")

    // Frame 3: holding and moving the mouse drags the window by the exact delta.
    let beta_pre = win(u, "Beta")
    let ox = beta_pre.x
    let oy = beta_pre.y
    draw.begin(u.style.bg)
    u.begin()
    u.hover_win = beta_id
    u.down = true
    u.was  = true
    u.mx   = ox + 10 + 30
    u.my   = oy + 5 + 20
    u.window_begin("Beta")  u.window_end()
    draw.finish()
    let beta3 = win(u, "Beta")
    println("dx={beta3.x - ox} dy={beta3.y - oy}")

    // Input routing: a widget engages only when its window is the one under the mouse.
    u.cur_win = 99
    u.hover_win = 99
    u.mx = 50  u.my = 50  u.down = true  u.was = false  u.active = -1
    u.press(7, 40, 40, 40, 40)
    let hovered_active = u.active

    u.active = -1
    u.cur_win = 99
    u.hover_win = 88
    u.press(7, 40, 40, 40, 40)
    let occluded_active = u.active
    println("hovered_active={hovered_active} occluded_active={occluded_active}")

    draw.close()
    return 0
}
