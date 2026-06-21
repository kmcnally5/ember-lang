// tests/graphics/flare_page.em — regression for page_begin/page_end (a CENTRED max-width content column).
// A 400px page in an 800px window sits centred — its content starts near x=200 (margin ≈ (800-400)/2), not
// hugging the left at ~x=10. Two frames; no input. Centring is pure geometry (window vs page width), so this
// is font-metric independent.
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(800, 160, "flarepagetest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_page.tape")
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.page_begin(400)
        f.label("centered")
        f.page_end()
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_page.tape"))
    return 0
}
