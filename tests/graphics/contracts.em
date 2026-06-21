// tests/graphics/contracts.em — regression for contracts on UI state (MANIFESTO §5e).
// The slider carries an executable spec: `requires lo < hi` (which also guards its
// `(hi - lo)` divisions) and `ensures` the returned value is within [lo, hi]. This
// checks the postcondition's observable behaviour: an out-of-range stored value is
// clamped into range even when the slider isn't being dragged. (A `requires` violation
// aborts with a structured contract_violation event on the tape — shown in the docs,
// not asserted here since it terminates the program.)

import "std/draw" as draw
import "std/ui" as ui

fn main() -> int {
    draw.window(120, 80, "contracts")
    var u = ui.new()
    draw.begin(u.style.bg)
    u.begin()
    let hi = u.slider("a", 999, 0, 100)    // above range -> clamped to hi
    let lo = u.slider("b", -50, 0, 100)    // below range -> clamped to lo
    let mid = u.slider("c", 42, 0, 100)    // in range -> unchanged
    u.end()
    draw.finish()
    draw.close()
    println("hi={hi} lo={lo} mid={mid}")
    return 0
}
