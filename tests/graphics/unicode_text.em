// tests/graphics/unicode_text.em — regression for the on-demand Unicode glyph cache (OFI-069).
// The font atlas is seeded with ASCII and grows lazily: the first time a string contains a code
// point the face has but the atlas doesn't, gfx_size_ensure rasterises it and rebuilds the atlas.
// This exercises that whole path — UTF-8 decode, membership, rebuild, draw, AND measure_text (which
// bakes glyphs too) — with the exact non-ASCII glyphs the Claude-desktop app draws (✕ was dropped
// because Inter lacks U+2715; × / ↑ / … / — / · / accents / curly quotes all render). The tape
// records the draw_text ops with their UTF-8 strings + the measure-driven marker x, so a crash or a
// corrupted decode in the grow path breaks the golden. (Pixel correctness — that the glyph actually
// rasterised rather than falling back to '?' — is verified separately by a framebuffer capture.)
import "std/draw" as draw

fn main() -> int {
    draw.window(700, 240, "unicodetext")
    draw.tape_on("/tmp/ember_unicode_test.tape")

    // The app's real non-ASCII chrome + typed/pasted text, all in one frame so the atlas grows once.
    let lines = [
        "close: ×   send: ↑   more: …",
        "Optional — steer Claude's behaviour",
        "Settings · Opus 4.8 · café résumé",
        "curly quotes “like this” and ‘this’"
    ]

    draw.begin(1710618)
    var i = 0
    loop {
        if i == lines.len() { break }
        let s = lines[i]
        let y = 24 + i * 44
        draw_text(s, 24, y, 24, 16777215)
        // a marker at the measured end of the line: its x encodes measure_text over the SAME glyphs,
        // so a baked-glyph advance regression (e.g. a dropped code point) shifts it and fails the golden.
        draw_rect(24 + measure_text(s, 24), y, 2, 24, 8947848)
        i = i + 1
    }
    draw.finish()

    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_unicode_test.tape"))
    return 0
}
