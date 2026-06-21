// 18_flare_anim.em — Flare ANIMATION: spring physics + FLIP layout transitions (MANIFESTO §5g). Two
// techniques modern UIs lean on, made nearly free by immediate mode + Ember's determinism:
//
//   • f.spring(key, target) eases a value toward `target` over a FIXED timestep — INTERRUPTIBLE by
//     construction (retarget any frame and it redirects smoothly, velocity intact) and DETERMINISTIC
//     (a pure function of frame count, no wall-clock). Here it drives a panel's WIDTH; f.at(dx,dy){…}
//     would instead slide a subtree's PAINT without disturbing layout.
//   • f.animate_layout(key){…} AUTO-animates a widget that MOVED because the layout changed (the "FLIP"
//     technique). Flare already re-solves real flexbox every frame AND caches every widget's last rect,
//     so the spring just rides the difference — add/remove a row at the top and the rows below SLIDE to
//     their new slots instead of teleporting. Give each row a STABLE key so the animation follows it.
//
//   make graphics && EMBER_STD=./std build/emberc-gfx --emit=run examples/graphics/18_flare_anim.em

import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(640, 480, "Flare — animation")
    var f = flare.new()
    var expanded = false
    var items: [int] = [0, 1, 2]
    var next_id = 3

    loop {
        if draw.closing() {
            break
        }
        draw.begin(f.bg())
        f.begin()

        f.heading("Flare animation")
        f.text_muted("Spring physics + FLIP layout transitions — deterministic, immediate-mode.")

        // 1) SPRING — a panel whose width eases between two sizes. Toggle it; the width RETARGETS smoothly
        //    even mid-flight. Wrapped in a row + spacer so it stays content-width (a panel alone would stretch).
        if f.primary("Toggle width") {
            expanded = !expanded
        }
        var tw = 160.0
        if expanded {
            tw = 460.0
        }
        let w = f.spring("panel_w", tw)
        f.row(flare.START, flare.CENTER)
        f.panel_begin(flare.START, flare.CENTER)
        f.strut(to_int(w), 56)
        f.label("width springs to {to_int(w)}px")
        f.end()
        f.spacer()
        f.end()

        // 2) FLIP — add/remove a row at the TOP; the rows below spring to their new position, no teleport.
        f.row(flare.START, flare.CENTER)
        if f.button("Add row") {
            var nl: [int] = []
            nl.append(next_id)
            next_id = next_id + 1
            var j = 0
            loop {
                if j == items.len() {
                    break
                }
                nl.append(items[j])
                j = j + 1
            }
            items = nl
        }
        if f.button("Remove row") {
            if items.len() > 0 {
                let _ = items.remove_at(0)
            }
        }
        f.end()

        var i = 0
        loop {
            if i == items.len() {
                break
            }
            f.animate_layout("row:{items[i]}")        // STABLE key → the animation follows the row, not the slot
            f.panel_begin(flare.START, flare.CENTER)
            f.label("Row #{items[i]}")
            f.end()
            f.end_animate_layout()
            i = i + 1
        }

        f.finish()
        draw.finish()
    }

    draw.close()
    return 0
}
