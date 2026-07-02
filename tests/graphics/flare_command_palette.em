// tests/graphics/flare_command_palette.em — regression for std/flare's command_palette (⌘K): a centred
// modal (scrim + card, layer 2000000) holding a live filter field and a keyboard-navigable list of the
// commands whose label matches the query (case-insensitive substring). The first match is highlighted
// (the accent fill — the ↑/↓ selection), so Enter would activate it.
//
// Determinism: the palette auto-focuses its field on open, so a real run would edit the field's own
// buffer. The test BLURS the field (f.ui.focus = 0) on the taped frame and seeds the query via set_str,
// which makes text_field take the passed value — so the filtered list ("zoom" → Zoom In / Zoom Out) is
// fixed regardless of the hardware cursor. Three warm-up frames settle the rects and pass the one-shot
// fresh-open reset; the fourth, taped frame is asserted.
//
// NOTE (OFI-068): text x/width drift ±1px across freetype builds — re-bless per machine if needed; the
// scrim, modal card, field, and the two list rows (with the accent selection) are the stable structure.
import "std/draw" as draw
import "std/flare" as flare


fn cmds() -> [string] {
    return ["New chat", "Settings", "Toggle Theme", "Zoom In", "Zoom Out", "Reset Layout", "Show Inspector"]
}


fn main() -> int {
    draw.window(640, 440, "flarecmdpalettetest")
    var f = flare.new()
    f.use_dark()

    var i = 0
    loop {
        if i == 3 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        let _ = f.command_palette("cmdk", cmds())
        f.finish()
        draw.finish()
        i = i + 1
    }

    draw.tape_on("/tmp/ember_flare_command_palette.tape")
    draw.begin(f.bg())
    f.begin()
    f.ui.focus = 0                       // blur so text_field takes the seeded value (a real run stays focused)
    f.set_str("cmdk.q", "zoom")
    let _ = f.command_palette("cmdk", cmds())
    f.finish()
    draw.finish()
    draw.tape_off()

    draw.close()
    print(read_file("/tmp/ember_flare_command_palette.tape"))
    return 0
}
