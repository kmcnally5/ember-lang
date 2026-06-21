// tests/graphics/splitter.em — regression for the draggable resize/split control (std/ui _split_drag, the
// engine behind std/flare's f.splitter). Drives the latch directly with injected mouse state across a full
// press → drag → clamp → release sequence and prints the returned pane size each frame, so the golden is
// deterministic WITHOUT a real mouse (input injected like text_field.em). It pins the load-bearing logic:
//   * ABSOLUTE-ANCHOR math — new size = size-at-press + the mouse's TOTAL travel since the press, so the
//     result is independent of the handle's own position (which moves under the cursor as the pane resizes);
//   * both CLAMPS (drag past hi → hi; past lo → lo);
//   * the latch lifecycle — a press DOWN-edge latches, release clears it (a later move then does nothing).
// The handle rect (x=200,w=6) is only ever used for the over-hit-test, never in the delta — proven by frame 3+
// where the mouse leaves the band yet the drag keeps tracking.
import "std/draw" as draw
import "std/ui" as ui


fn main() -> int {
    draw.window(420, 320, "splittertest")
    var u = ui.new()
    let id = u.wid("sb")              // any stable widget id
    let bx = 200                      // handle band: x in [200,206), full height
    let lo = 200
    let hi = 480

    // Frame 1 — idle, cursor over the band, button up: no latch, size unchanged.
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 203  u.my = 100  u.down = false  u.was = false
    var size = u._split_drag(id, bx, 0, 6, 320, true, true, 236, lo, hi)
    var dragging = u.sp_drag == id
    print("f1 size={size} dragging={dragging}\n")
    draw.finish()

    // Frame 2 — press DOWN-edge on the band: latches (grab=203, base=236), size still 236 (zero travel yet).
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 203  u.my = 100  u.down = true  u.was = false
    size = u._split_drag(id, bx, 0, 6, 320, true, true, size, lo, hi)
    dragging = u.sp_drag == id
    print("f2 size={size} dragging={dragging}\n")
    draw.finish()

    // Frame 3 — hold + drag right +60px; cursor has LEFT the 6px band but the drag still tracks (absolute anchor).
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 263  u.my = 100  u.down = true  u.was = true
    size = u._split_drag(id, bx, 0, 6, 320, true, true, size, lo, hi)
    dragging = u.sp_drag == id
    print("f3 size={size} dragging={dragging}\n")
    draw.finish()

    // Frame 4 — drag far right (mx=700): raw size would be 733, clamped to hi=480.
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 700  u.my = 100  u.down = true  u.was = true
    size = u._split_drag(id, bx, 0, 6, 320, true, true, size, lo, hi)
    dragging = u.sp_drag == id
    print("f4 size={size} dragging={dragging}\n")
    draw.finish()

    // Frame 5 — drag far left (mx=10): raw size would be 43, clamped to lo=200.
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 10  u.my = 100  u.down = true  u.was = true
    size = u._split_drag(id, bx, 0, 6, 320, true, true, size, lo, hi)
    dragging = u.sp_drag == id
    print("f5 size={size} dragging={dragging}\n")
    draw.finish()

    // Frame 6 — release (button up): the latch clears; size holds at the last clamped value.
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 10  u.my = 100  u.down = false  u.was = true
    size = u._split_drag(id, bx, 0, 6, 320, true, true, size, lo, hi)
    dragging = u.sp_drag == id
    print("f6 size={size} dragging={dragging}\n")
    draw.finish()

    // Frame 7 — moving with the button still up does NOTHING (proves release truly ended the drag).
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 700  u.my = 100  u.down = false  u.was = false
    size = u._split_drag(id, bx, 0, 6, 320, true, true, size, lo, hi)
    dragging = u.sp_drag == id
    print("f7 size={size} dragging={dragging}\n")
    draw.finish()

    // --- before=false: a handle resizing the pane AFTER it — dragging toward the handle SHRINKS that pane, so
    // the delta sign is inverted. base=300; drag right +40 → 300-40=260 (strictly inside [200,480], so a value
    // reachable ONLY with the sign flip — a non-flipped path would give 340). Proves the `before` branch. ---
    let id2 = u.wid("bf")
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 203  u.my = 100  u.down = true  u.was = false           // press the handle (latch base=300)
    var s2 = u._split_drag(id2, bx, 0, 6, 320, true, false, 300, 200, 480)
    print("bf1 size={s2}\n")
    draw.finish()
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 243  u.my = 100  u.down = true  u.was = true            // drag right +40 → inverted → 260
    s2 = u._split_drag(id2, bx, 0, 6, 320, true, false, s2, 200, 480)
    print("bf2 size={s2}\n")
    draw.finish()

    // --- vertical=false: a HORIZONTAL bar dragged along Y (resizes height). The band is wide+short at y=200.
    // It must read the my axis, not mx: we move my +60 (160→220) while mx jumps +200 as a trap — a value of 220
    // proves my (not mx) drives the size. ---
    let id3 = u.wid("hb")
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 100  u.my = 203  u.down = true  u.was = false           // press the horizontal band (latch base=160)
    var s3 = u._split_drag(id3, 0, 200, 400, 6, false, true, 160, 100, 300)
    print("hb1 size={s3}\n")
    draw.finish()
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 300  u.my = 263  u.down = true  u.was = true            // my +60 (→220); mx +200 is a trap it must ignore
    s3 = u._split_drag(id3, 0, 200, 400, 6, false, true, s3, 100, 300)
    print("hb2 size={s3}\n")
    draw.finish()

    // --- split_release: the hook the modal gate uses to drop a HELD latch without calling _split_drag, so a
    // drag can't survive (and then jump) while a dialog covers the panes. Latch a drag, then release it. ---
    let id4 = u.wid("rel")
    draw.begin(u.style.bg)
    u.begin()
    u.mx = 203  u.my = 100  u.down = true  u.was = false
    let _ = u._split_drag(id4, bx, 0, 6, 320, true, true, 236, lo, hi)
    print("rel1 dragging={u.sp_drag == id4}\n")                    // latched by the press
    u.split_release(id4)
    print("rel2 dragging={u.sp_drag == id4}\n")                    // dropped — no latch survives to jump on resume
    draw.finish()

    draw.close()
    return 0
}
