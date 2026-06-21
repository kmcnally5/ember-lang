// tests/graphics/flare_splitter.em — regression for the Flare splitter WIDGET (std/flare f.splitter + the _SPLIT
// paint arm), the layer above the std/ui _split_drag latch that splitter.em covers. It drives the real widget:
// a sidebar panel (strut sbw) | f.splitter | main panel, taping the painted handle and printing the returned
// width. Input is injected (mx/down/was set after f.begin, like text_field.em) at the handle's solved position,
// so it pins: the rect round-trip (input runs against LAST frame's solved rect), the _SPLIT hairline paint at the
// sidebar's right edge with its hover/drag colour, and the value = f.splitter(...) resize result. No text → the
// golden is font-metric-independent (immune to the OFI-068 ±1px drift the other flare goldens carry).
//
// Geometry (default theme: pad 10): sidebar panel = strut(sbw) + 2·pad, then a row gap (pad), so the 6px handle
// band sits at x = 10 + (sbw+20) + 10; its centred hairline is at band_left + 2. At sbw=236 → band 276, line 278.
import "std/draw" as draw
import "std/flare" as flare


fn body(mut f: flare.Flare, sbw: int) -> int {
    f.row_grow(flare.START, flare.STRETCH)
    f.panel_begin(flare.START, flare.START)        // the sidebar surface, width pinned by the strut
    f.strut(sbw, 0)
    f.end()
    let w = f.splitter("sb", sbw, 200, 480, true)  // the drag handle on its right edge
    f.panel_begin(flare.START, flare.STRETCH)      // the main pane (fills the rest is fine; panel just paints it)
    f.strut(0, 0)
    f.end()
    f.end()
    return w
}


fn main() -> int {
    draw.window(520, 240, "flaresplittertest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_splitter.tape")

    // Frame 1 — no input: lay out + paint so the handle's rect is recorded for next frame; the hairline is IDLE.
    draw.begin(f.bg())
    f.begin()
    f.ui.mx = -1  f.ui.my = -1  f.ui.down = false  f.ui.was = false
    var sbw = body(f, 236)
    f.finish()
    draw.finish()
    print("f1 sbw={sbw}\n")

    // Frame 2 — press the handle (over its frame-1 rect at x≈278): latches the drag; hairline turns ACCENT.
    draw.begin(f.bg())
    f.begin()
    f.ui.mx = 278  f.ui.my = 120  f.ui.down = true  f.ui.was = false
    sbw = body(f, sbw)
    f.finish()
    draw.finish()
    print("f2 sbw={sbw}\n")

    // Frame 3 — drag right +100px: f.splitter RETURNS 336 (absolute-anchor), but the panel laid out THIS frame is
    // still 236 wide, so the hairline is still at x=278 — the idiomatic 1-frame lag (new size applies next frame).
    draw.begin(f.bg())
    f.begin()
    f.ui.mx = 378  f.ui.my = 120  f.ui.down = true  f.ui.was = true
    sbw = body(f, sbw)
    f.finish()
    draw.finish()
    print("f3 sbw={sbw}\n")

    // Frame 4 — release, re-render at the new width: the sidebar panel is now 336 wide and the handle has moved
    // to its new right edge (x ≈ 378), back to the idle colour. Proves the handle tracks the resized pane.
    draw.begin(f.bg())
    f.begin()
    f.ui.mx = 100  f.ui.my = 120  f.ui.down = false  f.ui.was = true
    sbw = body(f, sbw)
    f.finish()
    draw.finish()
    print("f4 sbw={sbw}\n")

    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_splitter.tape"))
    return 0
}
