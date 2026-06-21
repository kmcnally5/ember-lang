// tests/graphics/flare_modal.em — regression for std/flare's modal + segmented + divider, which rest on
// the new FLOATING node in std/layout. modal_begin opens a centred dialog over a DIMMED SCRIM (a
// full-window rounded rect at MODAL_LAYER), holding a heading, a hairline divider, a segmented control
// whose SELECTED option is filled with the clay accent, and a primary button — all painted on the modal
// layer ABOVE the background "behind the modal" label (layer 0). The panel is centred: for a 300-wide
// dialog in a 360-wide window its x is (360-300)/2 = 30. Two frames so the solved rect is stable; no
// input is injected (the click path reuses std/ui's press, covered elsewhere).
//
// NOTE (OFI-068): text x-positions and widths shift ±1px with the freetype build, so this golden may
// need re-blessing on another machine (`tests/run-graphics.sh --update`), exactly like the sibling
// flare.em — the shape ops (scrim, panel, divider, accent fills) are the stable part being asserted.
import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(360, 300, "flaremodaltest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_modal.tape")
    var mode = 0
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.label("behind the modal")
        let open = f.modal_begin("dlg", 300, 0)
        if !open {
            mode = 0
        }
        f.heading("Settings")
        f.divider()
        mode = f.segmented("mode", ["Dark", "Light"], mode)
        if f.primary("Done") {
            mode = 0
        }
        f.modal_end()
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_modal.tape"))
    return 0
}
