// tests/graphics/flare_typeahead.em — regression for std/flare's composer typeahead: an anchored completion
// popup for a text field (slash-commands / @-mentions). Given a partial `query` and candidate labels it
// filters them (case-insensitive substring) and lists them keyboard-navigably in a card ABOVE the anchor
// field (layer 2000000), first match highlighted (the accent selection). Here the field holds "/s" and the
// query "s" narrows ["new","settings","theme","copy","quit"] to just "settings". Warm-up frames settle the
// anchor field's rect (the popup positions itself relative to it); the last frame is asserted.
//
// NOTE (OFI-068): text x/width drift ±1px across freetype builds — re-bless per machine if needed; the
// popup card and the highlighted row are the stable structure.
import "std/draw" as draw
import "std/flare" as flare


fn cmds() -> [string] {
    return ["new", "settings", "theme", "copy", "quit"]
}


fn body(mut f: flare.Flare, q: string) {
    f.column(flare.START, flare.STRETCH)
    f.heading("Composer typeahead")
    f.spacer()
    let _ta = f.typeahead("ta", "composer", q, cmds())
    let _in = f.text_area("composer", "/" + q)
    f.end()
}


fn main() -> int {
    draw.window(420, 320, "flaretypeaheadtest")
    var f = flare.new()
    f.use_dark()
    var i = 0
    loop {
        if i == 3 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        body(f, "s")
        f.finish()
        draw.finish()
        i = i + 1
    }
    draw.tape_on("/tmp/ember_flare_typeahead.tape")
    draw.begin(f.bg())
    f.begin()
    body(f, "s")
    f.finish()
    draw.finish()
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_typeahead.tape"))
    return 0
}
