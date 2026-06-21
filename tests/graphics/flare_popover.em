// tests/graphics/flare_popover.em — regression for std/flare's ghost_button + popover + menu_item, built
// on the anchored float (std/layout.open_float_at). A ghost button is borderless (muted text, hover-fill);
// popover_begin opens an anchored menu card on the modal layer (NO scrim) at the given point, holding
// menu_items (full-width rows, accent on hover). Two frames; no input injected (the menu stays open).
//
// NOTE (OFI-068): text x-positions/widths drift ±1px across freetype builds — re-bless per machine if
// needed; the popover card (round on layer 2000000) and the menu-item rows are the stable shape ops.
import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(400, 300, "flarepopovertest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_popover.tape")
    var touched = false
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        if f.ghost_button("Copy") {
            touched = true
        }
        let open = f.popover_begin("menu", 120, 80)
        if f.menu_item("Delete chat") {
            touched = true
        }
        if f.menu_item("Rename") {
            touched = true
        }
        f.popover_end()
        if !open {
            touched = true
        }
        if touched {
            frame = frame + 1
        }
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_popover.tape"))
    return 0
}
