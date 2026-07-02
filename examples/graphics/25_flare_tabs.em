// 25_flare_tabs.em — closeable, reorderable TABS on Flare (MANIFESTO §5g). A browser/editor-style tab strip:
// click a tab to switch (the active one is raised with an accent underline), click its "×" to close it, and
// DRAG a tab left/right to reorder. tabs() returns a TabResult — active / closed / moved_from / moved_to — and
// the caller edits its own list; the chips FLIP-animate to their new slots (keyed by label, so the motion
// follows the tab). "+ New tab" adds one.
//
//   make graphics && build/emberc-gfx --emit=run examples/graphics/25_flare_tabs.em

import "std/draw" as draw
import "std/flare" as flare


// insert_at returns `arr` with `val` inserted before index `idx` (idx == len → appended). Ember arrays have
// append/remove_at but no insert, so a reorder is remove_at(from) then this.
fn insert_at(arr: [string], idx: int, val: string) -> [string] {
    var out: [string] = []
    var k = 0
    loop {
        if k == arr.len() {
            break
        }
        if k == idx {
            out.append(val)
        }
        out.append(arr[k])
        k = k + 1
    }
    if idx >= arr.len() {
        out.append(val)
    }
    return out
}


fn main() -> int {
    draw.window(620, 300, "Tabs")
    var f = flare.new()

    var tabs = ["Overview", "Design", "Notes"]
    var active = 0
    var next_n = 4

    loop {
        if draw.closing() {
            break
        }
        draw.begin(f.bg())
        f.begin()

        f.row(flare.START, flare.CENTER)
        let r = f.tabs("docs", tabs, active)
        f.spacer()
        if f.button("+ New tab") {
            tabs.append("Doc {next_n}")
            active = tabs.len() - 1
            next_n = next_n + 1
        }
        f.end()

        // apply the frame's tab actions to our own list
        active = r.active
        if r.closed >= 0 {
            tabs.remove_at(r.closed)
            if active >= r.closed && active > 0 {
                active = active - 1        // keep the same tab selected as the list shifts left
            }
            if active >= tabs.len() {
                active = tabs.len() - 1
            }
            if active < 0 {
                active = 0
            }
        }
        if r.moved_from >= 0 && r.moved_to >= 0 {
            let moved = tabs[r.moved_from]
            let was_active = active == r.moved_from
            tabs.remove_at(r.moved_from)
            tabs = insert_at(tabs, r.moved_to, moved)
            if was_active {
                active = r.moved_to        // the selection follows the dragged tab
            }
        }

        f.divider()
        if tabs.len() > 0 {
            f.heading(tabs[active])
            f.text_muted("Tab {active} of {tabs.len()} — click a tab, its ×, or drag to reorder.")
        } else {
            f.text_muted("No tabs — add one.")
        }

        f.finish()
        draw.finish()
    }
    draw.close()
    return 0
}
