// std/flare — declarative, component-style UI for Ember (MANIFESTO §5g), now with a REAL flexbox
// layout engine and a warm, Claude-inspired house look.
//
// React's ergonomics, none of its machinery: components are functions, events are RETURN VALUES
// (`if f.button("Save") {…}`, not callbacks), props are typed arguments, state is plain `var`s the
// loop owns (or `f.state_*` for state encapsulated in a reusable component). The Virtual DOM exists
// only because the real DOM is retained and slow to mutate; Ember redraws every frame cheaply, so
// that machinery solves a problem we don't have.
//
// LAYOUT is real flexbox (std/layout). Each frame Flare builds an EPHEMERAL tree of boxes as you
// declare the UI, solves it (measure → place), then paints each widget at its solved rectangle —
// nothing retained, so the immediate-mode bet holds. Value-returning widgets keep working via the
// last-frame trick: a click tests against the widget's solved rect from the PREVIOUS frame (stable,
// so imperceptible). Containers nest: `column`/`row` with `justify` (main axis) and `align` (cross
// axis), `spacer()` to push things apart, `grow` to fill. The vocabulary every model knows cold.
//
//   f.begin()
//   f.row(flare.BETWEEN, flare.CENTER)        // a toolbar
//       f.heading("Inbox")
//       f.spacer()
//       if f.primary("Compose") { ... }
//   f.end()
//   f.finish()

import "std/ui" as ui
import "std/map" as map
import "std/layout" as lay
import "std/markdown" as md
import "std/highlight" as hl
import "std/string" as str


// Layout constants, re-exported so an app only imports std/flare. (Mirror std/layout's values.)
let COL     = 0
let ROW     = 1
let START   = 0
let CENTER  = 1
let END     = 2
let BETWEEN = 3
let STRETCH = 3

// Widget kinds in the paint queue.
let _LABEL   = 0
let _BUTTON  = 1   // secondary (panel) button
let _PRIMARY = 2   // accent (clay) button — the headline action
let _HEADING = 3
let _MUTED   = 4
let _FIELD   = 5   // text input (std/ui text_field, painted at the solved rect)
let _PANEL   = 6   // a CONTAINER with a painted surface (queued before its children)
let _SCROLL_BEGIN = 7   // a CONTAINER marker: clip to the viewport + offset children by the scroll amount
let _SCROLL_END   = 8   // close the scroll viewport (clip_pop, reset the offset)
let _CODE  = 9   // a monospace, syntax-highlighted code panel (text = source, id = language)
let _QUOTE = 10  // a blockquote: an accent bar + indented muted lines (text = pre-wrapped lines)
let _MODAL_BEGIN = 11   // a floating dialog OPENS: raise the draw layer, paint the scrim + panel surface
let _MODAL_END   = 12   // the floating dialog CLOSES: drop back to the base layer
let _DIVIDER = 13       // a full-width hairline rule (a section separator)
// Inline rich-text run kinds (a wrapped line is a row of these). They double as the paint kind AND the
// word's style tag during wrapping, so one int carries both. _LABEL (0) is a normal run.
let _BOLD  = 14   // an inline **bold** run — faux-bold (drawn twice, 1px apart) in the body face
let _ICODE = 15   // an inline `code` run — the monospace face on a tinted chip
let _EM    = 16   // an inline *italic* run — the italic face
let _LINK  = 17   // an inline [link](url) run — accent colour + underline (not yet clickable)
let _H1 = 18      // a Markdown heading, level 1 (largest, faux-bold, left-aligned); _H2/_H3 step down
let _H2 = 19
let _H3 = 20      // level 3 and deeper
let _AVATAR = 21  // a small rounded accent badge with a centred glyph (a chat / identity mark)
let _BUBBLE = 22  // a rounded, tinted message container (a chat bubble) — like _PANEL, rounder
let _GHOST = 23   // a subtle, borderless action button (no fill at rest, hover-fill, muted ink)
let _POPOVER_BEGIN = 24   // an anchored floating menu OPENS (no scrim): raise the layer, paint its card
let _POPOVER_END   = 25
let _MENUITEM = 26   // a full-width selectable row inside a popover (accent on hover)
let _TAREA = 27      // a multi-line, auto-growing text area (std/ui _ta_edit/_ta_draw at the solved rect)
let _SPLIT = 28      // a draggable resize handle between two panes (a hairline in a wide hit band)
let _NAVITEM    = 29   // a full-width sidebar nav row: LEFT-aligned text, GROWS to fill the panel width
let _NAVITEM_ON = 30   // the active/selected nav row — the accent fill, like _PRIMARY
let _OFFSET_BEGIN = 31 // a paint-queue bracket: shift the enclosed widgets' PAINT by (dx,dy), layout untouched
let _OFFSET_END   = 32 // close a paint-offset bracket
let _FLIP_BEGIN = 33   // FLIP: auto-animate a subtree that MOVED in the layout solve (spring old→new position)
let _FLIP_END   = 34   // close a FLIP bracket

// HANDLE_W is the on-screen thickness (px) of a splitter's hit band — wide enough to grab, a hairline to look
// at. Public so a caller can account for it when computing the remaining content width beside a resized pane.
let HANDLE_W = 6

// SPRING_DT is the FIXED animation timestep: every spring advances once per FRAME by this amount, so
// animation is a pure function of frame COUNT — deterministic and replayable (no wall-clock nondeterminism
// in the UI), at the cost of frame-rate-dependent wall time (fine at the 60fps the raylib backend targets).
let SPRING_DT = 0.0166667

let KEY_ENTER = 257   // raylib keycode; text_field reports Enter to the caller via submit()
let KEY_LSHIFT = 340  // Shift → newline in a text_area (plain Enter submits)
let KEY_RSHIFT = 344
let MODAL_LAYER = 2000000   // modals draw above everything, including std/ui's menus/tooltips (POPUP_LAYER)


// Rect is a solved widget rectangle (pixel coords). Flare remembers one per interactive widget
// so the NEXT frame's click can hit-test against where the widget actually landed.
struct Rect {
    x: int
    y: int
    w: int
    h: int
}


// theme_light is the warm "parchment + clay" Claude look — the house default.
fn theme_light() -> ui.Style {
    return ui.Style {
        bg: ui.rgb(247, 245, 242), panel: ui.rgb(255, 255, 255), hover: ui.rgb(244, 242, 238),
        pressed: ui.rgb(232, 228, 221), ink: ui.rgb(38, 36, 32), muted_ink: ui.rgb(124, 120, 112),
        accent: ui.rgb(196, 110, 78), accent_ink: ui.rgb(255, 255, 255), border: ui.rgb(220, 216, 209),
        track: ui.rgb(228, 224, 217), radius: 10, pad: 10, text_size: 19, row_h: 36, shadow: 22
    }
}


// theme_dark is the warm-neutral dark Claude look (same clay accent, lifted for a dark ground).
fn theme_dark() -> ui.Style {
    return ui.Style {
        bg: ui.rgb(38, 38, 36), panel: ui.rgb(46, 46, 43), hover: ui.rgb(58, 58, 54),
        pressed: ui.rgb(54, 54, 50), ink: ui.rgb(237, 234, 228), muted_ink: ui.rgb(150, 147, 139),
        accent: ui.rgb(204, 122, 90), accent_ink: ui.rgb(255, 255, 255), border: ui.rgb(58, 57, 53),
        track: ui.rgb(58, 57, 53), radius: 10, pad: 10, text_size: 19, row_h: 36, shadow: 55
    }
}


// wrap breaks `text` into lines that each fit within `max_w` pixels at `size`: existing newlines are
// hard breaks, the rest is greedy word-wrapped. A single word wider than max_w overflows its own line
// rather than being split mid-word. Used by f.paragraph for the transcript's prose.
fn wrap(text: string, max_w: int, size: int) -> [string] {
    var lines: [string] = []
    let paras = text.split(from_char_code(10))
    var p = 0
    loop {
        if p == paras.len() {
            break
        }
        let words = paras[p].split(" ")
        var cur = ""
        var i = 0
        loop {
            if i == words.len() {
                break
            }
            var trial = words[i]
            if cur.len() > 0 {
                trial = cur + " " + words[i]
            }
            if measure_text(trial, size) > max_w && cur.len() > 0 {
                lines.append(cur)
                cur = words[i]
            } else {
                cur = trial
            }
            i = i + 1
        }
        lines.append(cur)
        p = p + 1
    }
    return lines
}


// _strip removes inline emphasis markers (**bold**, *italic*, `code`) so prose renders clean instead of
// showing raw `**`. Styled inline rendering (bold weight, code tint) is a follow-on; this is the clean,
// reliable first step.
fn _strip(s: string) -> string {
    var t = concat(s.split("**"))
    t = concat(t.split("*"))
    t = concat(t.split("`"))
    return t
}


// spinner returns the current frame of a "- \ | /" throbber for frame counter `tick` (~10 changes/sec at
// 60fps). A tiny reusable loading indicator: e.g. `f.text_muted("Thinking " + flare.spinner(tick))`.
fn spinner(tick: int) -> string {
    let frames = ["-", "\\", "|", "/"]
    return frames[(tick / 6) % 4]
}


// _trim drops leading and trailing spaces (for parsing table cells out of "| a | b |").
fn _trim(s: string) -> string {
    let n = str.cp_count(s)
    var a = 0
    loop {
        if a >= n {
            break
        }
        if str.cp_slice(s, a, a + 1) != " " {
            break
        }
        a = a + 1
    }
    var b = n
    loop {
        if b <= a {
            break
        }
        if str.cp_slice(s, b - 1, b) != " " {
            break
        }
        b = b - 1
    }
    return str.cp_slice(s, a, b)
}


// _table_cells splits one table row "| a | b |" into its trimmed cell strings, dropping the empty edges
// the outer pipes produce (interior empty cells are kept).
fn _table_cells(row: string) -> [string] {
    let parts = row.split("|")
    var out: [string] = []
    var i = 0
    loop {
        if i == parts.len() {
            break
        }
        let t = _trim(parts[i])
        let edge_empty = (i == 0 || i == parts.len() - 1) && t.len() == 0
        if !edge_empty {
            out.append(t)
        }
        i = i + 1
    }
    return out
}


// Flare ties together the flexbox layout (std/layout), the std/ui primitive/visuals + input
// model, keyed identity (the IMGUI id-stack / React `key`), and encapsulated state. One per app,
// held as a `var` and threaded through the loop.
struct Flare {
    ui: ui.Ui
    si: map.Map<string, int>
    ss: map.Map<string, string>
    sb: map.Map<string, bool>
    sf: map.Map<string, float>      // float state column — drives springs (position + velocity per key)
    scope: string

    lo: lay.Layout                  // the per-frame layout tree
    rnode: [int]                    // paint queue: layout node index ...
    rkind: [int]                    // ... widget kind ...
    rtext: [string]                 // ... text ...
    rid: [string]                   // ... id string ("" if non-interactive)
    // Last frame's solved rect for each interactive widget, keyed by id. Rebuilt every frame in
    // finish() and read in _btn() to hit-test this frame's clicks. A struct-valued Map is safe now
    // that unique-owner aggregates deep-clone through erased generics (OFI-062/063 closed 2026-06-18).
    rects: map.Map<string, Rect>
    _submit: bool                   // set when Enter is pressed in a focused text_field; read via submit()
    mono: int                       // monospace font slot for code blocks + inline `code` (-1 = not loaded)
    italic: int                     // italic font slot for inline *emphasis* (-1 = not loaded)
    zoom: int                       // text-size zoom percent (100 = the theme's base 19px)
    _mdseq: int                     // per-frame counter giving each markdown code block a unique button id
    // Modal state. A modal captures input: while one is open the widgets BEHIND it go inert so clicks
    // don't fall through the scrim. The gate runs a frame behind (like the last-frame hit-test): begin()
    // seeds _modal from whether a modal was open LAST frame, and modal_begin() arms _modal_was for next.
    _modal: bool                    // a modal is active this frame → background widgets are inert
    _in_modal: bool                 // currently building the modal's OWN content → its widgets stay live
    _modal_was: bool                // a modal was opened last frame (seeds _modal at the next begin())


    // begin starts a frame: snapshot input, reset the layout tree, open the root column (it fills
    // the window and stretches its children to full width), and clear the paint queue.
    fn begin(mut self) {
        self.ui.begin()
        self.scope = ""
        self.ui.set_scope("")
        self._submit = false
        self._mdseq = 0
        self._modal = self._modal_was   // a modal was open last frame → gate the background this frame
        self._modal_was = false
        self._in_modal = false
        self.lo.reset()
        let pad = self.ui.style.pad
        let _ = self.lo.open(COL, START, STRETCH, pad, pad)
        self.rnode = []
        self.rkind = []
        self.rtext = []
        self.rid = []
    }


    // _si reads an int from the raw state map (no scope prefix) with a default — used for the
    // per-scroll-area offset/overflow/viewport that scroll_begin and finish() share by key.
    fn _si(self, key: string, dflt: int) -> int {
        match self.si.get(key) {
            case Some(v) { return v }
            case None {}
        }
        return dflt
    }


    // finish ends the frame: close the root, solve the tree against the window, paint every queued
    // widget at its solved rect, and remember those rects for next frame's hit-testing. A scroll
    // viewport (a _SCROLL_BEGIN..._SCROLL_END span) clips its region and shifts the widgets inside it
    // up by the scroll offset; it also records this frame's content overflow for next frame's clamp.
    fn finish(mut self) {
        self.lo.close()
        self.lo.solve(0, 0, screen_width(), screen_height())
        self.rects = map.Map<string, Rect>{ buckets: [], count: 0 }
        var scroll_dy = 0
        var ox = 0                  // paint-offset accumulators (f.at / FLIP); a stack so brackets nest
        var oy = 0
        var oxs: [int] = []
        var oys: [int] = []
        var i = 0
        loop {
            if i == self.rnode.len() {
                break
            }
            let kind = self.rkind[i]
            if kind == _SCROLL_BEGIN {
                let n  = self.rnode[i]
                let vx = self.lo.x(n)
                let vy = self.lo.y(n)
                let vw = self.lo.w(n)
                let vh = self.lo.h(n)
                var ov = self.lo.content_h(n) - vh   // how far the content overflows the viewport
                if ov < 0 {
                    ov = 0
                }
                let key = self.rid[i]
                self.si.set(key + ".max", ov)        // this frame's overflow → next frame's clamp
                self.si.set(key + ".vx", vx)         // viewport rect → a scroll_fab can anchor to it
                self.si.set(key + ".vy", vy)
                self.si.set(key + ".vw", vw)
                self.si.set(key + ".vh", vh)
                scroll_dy = self._si(key + ".off", 0)
                if scroll_dy > ov {              // pin the shift to the REAL overflow (resolves the sticky
                    scroll_dy = ov               // sentinel to the true bottom; also guards a content shrink)
                }
                clip_push(vx, vy, vw, vh)
            } else if kind == _SCROLL_END {
                clip_pop()
                scroll_dy = 0
            } else if kind == _MODAL_BEGIN {
                // A floating dialog: lift onto the modal layer (so it draws over everything), dim the whole
                // window as a scrim, then paint the centred panel surface. Its children follow on this layer.
                set_layer(MODAL_LAYER)
                let n  = self.rnode[i]
                let px = self.lo.x(n)
                let py = self.lo.y(n)
                let pw = self.lo.w(n)
                let ph = self.lo.h(n)
                fill_round(0, 0, screen_width(), screen_height(), 0, ui.rgb(0, 0, 0), 110)
                ui.card(px, py, pw, ph, self.ui.style.panel, self.ui.style, true)
                self.rects.set(self.rid[i], Rect { x: px, y: py, w: pw, h: ph })   // for next frame's scrim hit-test
            } else if kind == _MODAL_END {
                set_layer(0)
            } else if kind == _POPOVER_BEGIN {
                // An anchored menu: lift onto the modal layer and paint its raised card — no scrim, so the
                // background stays visible (but inert via the gate). Its menu_items follow on this layer.
                set_layer(MODAL_LAYER)
                let n  = self.rnode[i]
                let px = self.lo.x(n)
                let py = self.lo.y(n)
                let pw = self.lo.w(n)
                let ph = self.lo.h(n)
                ui.card(px, py, pw, ph, self.ui.style.panel, self.ui.style, true)
                self.rects.set(self.rid[i], Rect { x: px, y: py, w: pw, h: ph })   // for next frame's outside-press test
            } else if kind == _POPOVER_END {
                set_layer(0)
            } else if kind == _OFFSET_BEGIN {
                var dx = 0                              // shift the enclosed paint by (dx,dy); layout untouched
                var dy = 0
                let parts = self.rtext[i].split(",")
                if parts.len() == 2 {
                    dx = to_int(parse_float(parts[0]))
                    dy = to_int(parse_float(parts[1]))
                }
                oxs.append(dx)
                oys.append(dy)
                ox = ox + dx
                oy = oy + dy
            } else if kind == _FLIP_BEGIN {
                let n = self.rnode[i]
                let dx = self._flip_axis(self.rid[i] + ".x", self.lo.x(n))
                let dy = self._flip_axis(self.rid[i] + ".y", self.lo.y(n))
                oxs.append(dx)
                oys.append(dy)
                ox = ox + dx
                oy = oy + dy
            } else if kind == _OFFSET_END || kind == _FLIP_END {
                if oxs.len() > 0 {
                    let dx = oxs.remove_at(oxs.len() - 1)
                    let dy = oys.remove_at(oys.len() - 1)
                    ox = ox - dx
                    oy = oy - dy
                }
            } else {
                let n = self.rnode[i]
                let x = self.lo.x(n) + ox
                let y = self.lo.y(n) - scroll_dy + oy
                let w = self.lo.w(n)
                let h = self.lo.h(n)
                self._paint(kind, self.rtext[i], self.rid[i], x, y, w, h)
                if self.rid[i].len() > 0 {
                    self.rects.set(self.rid[i], Rect { x: x, y: y, w: w, h: h })
                }
            }
            i = i + 1
        }
        self.ui.end()
    }


    // bg is the active theme's background colour (pass to draw.begin()).
    fn bg(self) -> int {
        return self.ui.style.bg
    }


    // use_dark / use_light swap the house theme (warm Claude dark / parchment light), preserving zoom.
    fn use_dark(mut self) {
        self.ui.style = theme_dark()
        self._apply_zoom()
    }


    fn use_light(mut self) {
        self.ui.style = theme_light()
        self._apply_zoom()
    }


    // _apply_zoom scales the type metrics by the current zoom percent (the theme base is 100% = 19px
    // text). Everything — prose, headings, code, buttons, the composer — derives from text_size/row_h/
    // pad, so one rescale zooms the whole UI. Called after a theme swap or a zoom change.
    fn _apply_zoom(mut self) {
        self.ui.style.text_size = 19 * self.zoom / 100
        self.ui.style.row_h     = 36 * self.zoom / 100
        self.ui.style.pad       = 10 * self.zoom / 100
    }


    // zoom_by changes the text-size zoom by `delta` percent (⌘+/⌘-/⌘-scroll), clamped to 60–220%.
    // set_zoom sets the text-size zoom to `pct` percent (clamped 60–220) and rescales the type metrics, so
    // an app can pick its optimal default at startup (e.g. f.set_zoom(80)) and the settings stepper drives
    // it live from there.
    fn set_zoom(mut self, pct: int) {
        self.zoom = pct
        if self.zoom < 60 {
            self.zoom = 60
        }
        if self.zoom > 220 {
            self.zoom = 220
        }
        self._apply_zoom()
    }


    // zoom_by nudges the zoom by `delta` percent (⌘+/⌘-, the settings stepper).
    fn zoom_by(mut self, delta: int) {
        self.set_zoom(self.zoom + delta)
    }


    // ---- containers (flexbox) ----
    // column / row open a container; children flow along the main axis (column = down, row =
    // across), distributed by `justify` and aligned across by `align`. Pair with end().
    fn column(mut self, justify: int, align: int) {
        let _ = self.lo.open(COL, justify, align, self.ui.style.pad, 0)
    }


    fn row(mut self, justify: int, align: int) {
        let _ = self.lo.open(ROW, justify, align, self.ui.style.pad, 0)
    }


    // column_grow / row_grow are containers that GROW to fill their share of the parent's main axis
    // (flex-grow 1). A row_grow under the root column fills the window height; a main column_grow in a
    // row fills the width a fixed sidebar leaves; a transcript column_grow fills the height above a
    // pinned composer. Pair with end().
    fn column_grow(mut self, justify: int, align: int) {
        let _ = self.lo.open_grow(COL, justify, align, self.ui.style.pad, 0, 1)
    }


    fn row_grow(mut self, justify: int, align: int) {
        let _ = self.lo.open_grow(ROW, justify, align, self.ui.style.pad, 0, 1)
    }


    // panel_begin opens a CONTAINER (a vertical stack) whose rect is filled with the surface colour —
    // a sidebar or card background. The container node itself is queued for painting BEFORE its
    // children, so they draw on top. Padded so children inset from the edge; pair with end().
    fn panel_begin(mut self, justify: int, align: int) {
        let node = self.lo.open(COL, justify, align, self.ui.style.pad, self.ui.style.pad)
        self._queue(node, _PANEL, "", "")
    }


    // end closes the most recently opened container.
    fn end(mut self) {
        self.lo.close()
    }


    // spacer is a flexible, invisible gap: it grows to eat leftover main-axis space, pushing the
    // widgets after it to the far edge (the toolbar trick). Not painted.
    fn spacer(mut self) {
        let _ = self.lo.leaf(0, 0, 1)
    }


    // strut is a FIXED-size invisible leaf — a minimum extent. Dropped into a column it pins the
    // column's width (a clean sidebar); into a row, its height. Not painted.
    fn strut(mut self, w: int, h: int) {
        let _ = self.lo.leaf(w, h, 0)
    }


    // scroll_begin opens a scrollable viewport (a column that GROWS to fill its slot). Its children lay
    // out normally and may overflow; finish() clips them to the viewport and shifts them up by the
    // scroll offset, which the wheel drives while the pointer is over the viewport. `key` names the
    // area so its offset persists. Pair with scroll_end(key).
    fn scroll_begin(mut self, key: string) {
        self._scroll_begin(key, false)
    }


    // scroll_begin_sticky is scroll_begin for a CHAT transcript: it follows the bottom as content grows,
    // BUT only while you're already at the bottom. The wheel is applied FIRST, so scrolling up moves you
    // away from the bottom and the auto-follow disengages (you stay put); scrolling back to the bottom
    // re-engages it. This is the "stick to the latest unless I scroll away" behaviour. Pair with scroll_end.
    fn scroll_begin_sticky(mut self, key: string) {
        self._scroll_begin(key, true)
    }


    // Stick-to-bottom uses a separate `stick` flag (not the offset), so `off` stays the REAL position the
    // wheel can move; `stick` re-derives from "are we at the bottom" each frame. When stuck, off is the 1e6
    // sentinel and finish() pins the shift to the true overflow this frame (so follow includes new content).
    fn _scroll_begin(mut self, key: string, sticky: bool) {
        var off = self._si(key + ".off", 0)
        var stick = self._si(key + ".stick", 0)
        let mx = self._si(key + ".max", 0)       // last frame's overflow, to clamp against
        let vy = self._si(key + ".vy", 0)        // last frame's viewport, for the wheel hit-test
        let vh = self._si(key + ".vh", 0)
        if self.ui.my >= vy && self.ui.my < vy + vh {
            let w = mouse_wheel()
            if w != 0 {
                if stick == 1 {
                    off = mx                     // un-stick to the real bottom BEFORE applying the wheel
                }
                off = off - w * 40
                stick = 0                        // a manual wheel disengages follow...
            }
        }
        if off > mx {
            off = mx
        }
        if off < 0 {
            off = 0
        }
        if sticky {
            if off >= mx - 4 {                   // ...and being at/near the bottom (re)engages it
                stick = 1
            }
            if stick == 1 {
                off = 1000000                    // sentinel; finish() pins the shift to the real bottom
            }
        }
        self.si.set(key + ".off", off)
        self.si.set(key + ".stick", stick)
        let node = self.lo.open_grow(COL, START, STRETCH, self.ui.style.pad, 0, 1)
        self._queue(node, _SCROLL_BEGIN, "", key)
    }


    fn scroll_end(mut self, key: string) {
        self.lo.close()
        self._queue(0, _SCROLL_END, "", key)     // node index unused; finish() handles the marker
    }


    // page_begin opens a CENTERED, fixed-width content column — a readable "page" `width` px wide with
    // flexible margins on both sides (CSS `max-width` + `margin: auto`). Put content between page_begin and
    // page_end. The caller picks `width` (clamp it to the available space). Reusable for any centered
    // document/chat column. Implemented as a full-width row: [grow spacer | width column | grow spacer].
    fn page_begin(mut self, width: int) {
        self.row(START, STRETCH)         // a full-width row...
        self.spacer()                    // ...flexible left margin...
        self.column(START, STRETCH)      // ...the page column...
        self.strut(width, 0)             // ...pinned to `width`
    }


    fn page_end(mut self) {
        self.end()       // close the page column
        self.spacer()    // flexible right margin
        self.end()       // close the row
    }


    // scroll_to_bottom pins a scroll area to the end of its content (a fresh chat message). The big
    // value is clamped to the real overflow on the next frame's scroll_begin.
    fn scroll_to_bottom(mut self, key: string) {
        self.si.set(key + ".off", 1000000)
        self.si.set(key + ".stick", 1)           // jump to the bottom AND re-engage follow (for sticky areas)
    }


    // scroll_fab draws a round "jump to latest" button at the bottom-right of scroll area `key` whenever it
    // is scrolled UP (there's content below the fold), and returns whether it was clicked — wire it to
    // scroll_to_bottom(key). Like a tooltip it paints directly on a high layer and hit-tests its own stable
    // position (from last frame's stored viewport rect), so it needs no layout slot. Inert under a modal.
    fn scroll_fab(mut self, key: string) -> bool {
        if self._modal && !self._in_modal {
            return false
        }
        let off = self._si(key + ".off", 0)
        let max = self._si(key + ".max", 0)
        if max - off <= 8 {
            return false                          // already at the bottom → nothing to jump to
        }
        let vx = self._si(key + ".vx", 0)
        let vw = self._si(key + ".vw", 0)
        let vy = self._si(key + ".vy", 0)
        let vh = self._si(key + ".vh", 0)
        let st = self.ui.style
        let sz = st.row_h + 6
        let bx = vx + vw - sz - st.pad
        let by = vy + vh - sz - st.pad
        let wid = self.ui.wid(key + "_fab")
        let clicked = self.ui.press(wid, bx, by, sz, sz)
        set_layer(MODAL_LAYER - 1)
        shadow(bx, by + 2, sz, sz, sz / 2, st.shadow)
        var fill = st.panel
        if self.ui.hot == wid {
            fill = st.hover
        }
        fill_circle(bx + sz / 2, by + sz / 2, sz / 2, fill, 255)
        stroke_round(bx, by, sz, sz, sz / 2, 1, st.border, 160)
        let gs = st.text_size + 2
        let gw = measure_text("↓", gs)
        draw_text("↓", bx + (sz - gw) / 2, by + (sz - gs) / 2, gs, st.ink)
        set_layer(0)
        return clicked
    }


    // ---- modal (a floating dialog) ----
    // modal_begin opens a centred floating dialog `w`×`h` (h = 0 sizes to its content) on a dimmed
    // scrim. While it is open the widgets BEHIND it are inert — clicks can't fall through — and a press
    // on the scrim, outside the panel, dismisses it: modal_begin returns FALSE that frame, the caller's
    // cue to hide the modal. The dialog's OWN widgets stay live. Build the contents as a column, then
    // call modal_end(). The reusable basis for settings, confirmations and pickers.
    fn modal_begin(mut self, key: string, w: int, h: int) -> bool {
        self._modal_was = true       // gate the background NEXT frame (this frame's was built before us)
        self._in_modal  = true       // ...but the dialog's own widgets are live now
        var stay = true
        // Scrim dismissal: a fresh press OUTSIDE the panel's last-frame rect closes the dialog.
        if self.ui.down && !self.ui.was {
            match self.rects.get(key) {
                case Some(r) {
                    let inside = self.ui.mx >= r.x && self.ui.mx < r.x + r.w &&
                                 self.ui.my >= r.y && self.ui.my < r.y + r.h
                    if !inside {
                        stay = false
                    }
                }
                case None {}
            }
        }
        let pad = self.ui.style.pad
        let node = self.lo.open_float(COL, START, STRETCH, pad, pad, w, h)
        self._queue(node, _MODAL_BEGIN, "", key)
        return stay
    }


    fn modal_end(mut self) {
        self.lo.close()
        self._queue(0, _MODAL_END, "", "")
        self._in_modal = false
    }


    // popover_begin opens an anchored floating menu at (x, y) — a context menu / dropdown — WITHOUT a
    // dimmed scrim (the background stays visible but inert, like the modal). A press OUTSIDE the menu
    // returns false (the caller's cue to close it). Fill it with menu_item()s; close with popover_end().
    // Reuses the float node (anchored) + the modal input-gate. The reusable basis for right-click menus.
    fn popover_begin(mut self, key: string, x: int, y: int) -> bool {
        self._modal_was = true
        self._in_modal  = true
        var stay = true
        if self.ui.down && !self.ui.was {
            match self.rects.get(key) {
                case Some(r) {
                    let inside = self.ui.mx >= r.x && self.ui.mx < r.x + r.w &&
                                 self.ui.my >= r.y && self.ui.my < r.y + r.h
                    if !inside {
                        stay = false
                    }
                }
                case None {}
            }
        }
        let pad = self.ui.style.pad
        let node = self.lo.open_float_at(COL, START, STRETCH, 0, pad, x, y, 0, 0)
        self._queue(node, _POPOVER_BEGIN, "", key)
        return stay
    }


    fn popover_end(mut self) {
        self.lo.close()
        self._queue(0, _POPOVER_END, "", "")
        self._in_modal = false
    }


    // menu_item is one selectable, full-width row inside a popover; returns true when clicked. Its
    // intrinsic width sizes the popover (the widest item wins) and STRETCH makes every item that width.
    fn menu_item(mut self, txt: string) -> bool {
        let id = self.scope + "mi/" + txt
        let wid = self.ui.wid("mi/" + txt)
        let w = measure_text(txt, self.ui.style.text_size) + self.ui.style.pad * 3
        let h = self.ui.style.row_h
        var clicked = false
        if !(self._modal && !self._in_modal) {       // live while its popover is the active overlay
            match self.rects.get(id) {
                case Some(r) { clicked = self.ui.press(wid, r.x, r.y, r.w, r.h) }
                case None {}
            }
        }
        let node = self.lo.leaf(w, h, 0)
        self._queue(node, _MENUITEM, txt, id)
        return clicked
    }


    // ---- identity ----
    fn key(mut self, k: string) {
        self.scope = k + "/"
        self.ui.set_scope(self.scope)
    }


    fn key_clear(mut self) {
        self.scope = ""
        self.ui.set_scope("")
    }


    // ---- encapsulated state (the "hooks") ----
    fn state_int(self, key: string, dflt: int) -> int {
        match self.si.get(self.scope + key) {
            case Some(v) { return v }
            case None {}
        }
        return dflt
    }


    fn set_int(mut self, key: string, v: int) {
        self.si.set(self.scope + key, v)
    }


    fn state_str(self, key: string, dflt: string) -> string {
        match self.ss.get(self.scope + key) {
            case Some(v) { return v }
            case None {}
        }
        return dflt
    }


    fn set_str(mut self, key: string, v: string) {
        self.ss.set(self.scope + key, v)
    }


    fn state_bool(self, key: string, dflt: bool) -> bool {
        match self.sb.get(self.scope + key) {
            case Some(v) { return v }
            case None {}
        }
        return dflt
    }


    fn set_bool(mut self, key: string, v: bool) {
        self.sb.set(self.scope + key, v)
    }


    // ---- float state + springs (animation, over the fixed SPRING_DT timestep) ----

    fn state_float(self, key: string, dflt: float) -> float {
        match self.sf.get(self.scope + key) {
            case Some(v) { return v }
            case None {}
        }
        return dflt
    }


    fn set_float(mut self, key: string, v: float) {
        self.sf.set(self.scope + key, v)
    }


    // forget disposes a component's keyed state: it prunes every entry stored under `key`'s scope
    // (everything keyed `key + "/"…`, exactly what state_int/str/bool/float write after f.key(key))
    // from all four state columns. Call it when a component UNMOUNTS — a panel closed, a list row
    // deleted — so its state does not leak forever; without it the state maps only grow (set/get,
    // never remove). The prune walks a key SNAPSHOT (keys() returns a fresh list) so removing from
    // the live map mid-iteration is safe. Built on Map.remove; the discarded bool result is dropped.
    fn forget(mut self, key: string) {
        let prefix = key + "/"
        var ks = self.si.keys()
        var i = 0
        loop {
            if i == ks.len() { break }
            if str.starts_with(ks[i], prefix) { self.si.remove(ks[i]) }
            i = i + 1
        }
        ks = self.ss.keys()
        i = 0
        loop {
            if i == ks.len() { break }
            if str.starts_with(ks[i], prefix) { self.ss.remove(ks[i]) }
            i = i + 1
        }
        ks = self.sb.keys()
        i = 0
        loop {
            if i == ks.len() { break }
            if str.starts_with(ks[i], prefix) { self.sb.remove(ks[i]) }
            i = i + 1
        }
        ks = self.sf.keys()
        i = 0
        loop {
            if i == ks.len() { break }
            if str.starts_with(ks[i], prefix) { self.sf.remove(ks[i]) }
            i = i + 1
        }
    }


    // dock lays out and renders a DockTree at the given rect: it solves the tree, then paints every
    // panel as a themed frame (soft shadow, rounded fill, hairline border, a title bar) at its solved
    // rect. FLIP-style — each panel's drawn rect SPRINGS toward its solved target, so docking, closing,
    // or resizing a panel animates smoothly (deterministic, fixed timestep). The springs are keyed
    // "id/@d*", under each panel's scope, so f.forget(id) disposes a closed panel's animation state
    // too. Scope is saved/restored so dock() is a clean top-level call. Body content is a placeholder
    // for now; real per-panel widgets land with the docking UX (T5).
    fn dock(mut self, mut tree: DockTree, x: int, y: int, w: int, h: int) {
        let saved = self.scope
        self.scope = ""
        self.ui.set_scope("")
        tree.solve(x, y, w, h)
        var i = 0
        loop {
            if i == tree.dk_kind.len() { break }
            if tree.dk_kind[i] == 1 {
                self._draw_panel(tree.dk_panel[i], tree.dk_x[i], tree.dk_y[i], tree.dk_w[i], tree.dk_h[i])
            }
            i = i + 1
        }
        self.scope = saved
        self.ui.set_scope(saved)
    }


    fn _draw_panel(mut self, id: string, tx: int, ty: int, tw: int, th: int) {
        let st = self.ui.style
        let px = to_int(self.spring(id + "/@dx", to_float(tx)))
        let py = to_int(self.spring(id + "/@dy", to_float(ty)))
        let pw = to_int(self.spring(id + "/@dw", to_float(tw)))
        let ph = to_int(self.spring(id + "/@dh", to_float(th)))
        shadow(px, py + 3, pw, ph, st.radius, st.shadow)
        fill_round(px, py, pw, ph, st.radius, st.panel, 255)
        stroke_round(px, py, pw, ph, st.radius, 1, st.border, 160)
        let bar = st.row_h
        fill_round(px, py, pw, bar, st.radius, ui.shade(st.panel, 6), 255)
        draw_text(id, px + st.pad, py + (bar - st.text_size) / 2, st.text_size, st.ink)
        draw_text("(" + id + ")", px + st.pad, py + bar + st.pad, st.text_size, st.muted_ink)
    }


    // spring returns the current value of a named spring as it eases toward `target`, advancing it ONE fixed
    // timestep this frame. Its (position, velocity) live in two float-state keys; the FIRST frame a key is seen
    // snaps to `target` (no animate-in from zero). A spring RETARGETS for free — change the target any frame and
    // the motion redirects smoothly with velocity intact, exactly what an immediate-mode UI needs (the user keeps
    // interacting). A rest threshold settles it so a finished spring stops churning state. For spatial values —
    // a panel offset, a size, a scale; pair with at() to paint at the value.
    fn spring(mut self, key: string, target: float) -> float {
        return self._spring(key, target, 170.0, 26.0)      // SMOOTH preset: ~critically damped, no overshoot
    }


    // spring_with is spring() with an explicit (stiffness, damping): higher stiffness eases faster; damping
    // below 2*sqrt(stiffness) overshoots (a bounce). Tune per channel; the spring() defaults suit most motion.
    fn spring_with(mut self, key: string, target: float, stiffness: float, damping: float) -> float {
        return self._spring(key, target, stiffness, damping)
    }


    fn _spring(mut self, key: string, target: float, k: float, c: float) -> float {
        let pk = key + ".sp"
        let vk = key + ".sv"
        var pos = self.state_float(pk, target)              // unseen key → snap to target (no jump-from-zero)
        var vel = self.state_float(vk, 0.0)
        let force = (0.0 - k * (pos - target)) - c * vel     // F = -k·x - c·v
        vel = vel + force * SPRING_DT                        // semi-implicit Euler (update v, then x with new v)
        pos = pos + vel * SPRING_DT
        var adp = pos - target                               // settle when close AND slow → stop churning state
        if adp < 0.0 {
            adp = 0.0 - adp
        }
        var av = vel
        if av < 0.0 {
            av = 0.0 - av
        }
        if adp < 0.4 && av < 0.4 {
            pos = target
            vel = 0.0
        }
        self.set_float(pk, pos)
        self.set_float(vk, vel)
        return pos
    }


    // at shifts the PAINT of every widget built between it and end_at() by (dx, dy) pixels, WITHOUT moving them
    // in the layout solve — so the subtree slides OVER its neighbours instead of pushing them. Feed it a spring
    // for a drawer / sheet / floating panel:
    //   let x = f.spring("drawer", if open 0.0 else 0.0 - 300.0)
    //   f.at(x, 0.0); f.panel_begin(...); ...; f.panel_end(); f.end_at()
    // It is a pure paint-queue bracket (no layout node), so it never disturbs sizing; brackets nest freely.
    fn at(mut self, dx: float, dy: float) {
        let ix = to_int(dx)
        let iy = to_int(dy)
        self._queue(0, _OFFSET_BEGIN, "{ix},{iy}", "")
    }


    fn end_at(mut self) {
        self._queue(0, _OFFSET_END, "", "")
    }


    // animate_layout makes a subtree AUTO-ANIMATE when it MOVES because the layout changed — a sibling
    // appeared, a list reordered, a panel resized. This is "FLIP", and Flare gets it nearly for free: it
    // re-solves real flexbox every frame AND already caches every widget's last-frame rect, so last frame's
    // solved position is the "First" measurement and this frame's solve is the "Last" — the spring just rides
    // the difference. Wrap a subtree with a STABLE key; if its solved position jumps, it springs from the old
    // spot to the new instead of teleporting. Paint-time only — the layout solve is never perturbed.
    //   f.animate_layout("row:" + id); f.row(...); ...; f.end(); f.end_animate_layout()
    fn animate_layout(mut self, key: string) {
        let node = self.lo.open(COL, START, STRETCH, 0, 0)   // a group whose solved rect we measure each frame
        self._queue(node, _FLIP_BEGIN, "", self.scope + key)
    }


    fn end_animate_layout(mut self) {
        self.lo.close()
        self._queue(0, _FLIP_END, "", "")
    }


    // _flip_axis springs ONE axis of a FLIP offset toward 0, seeded each frame by the layout-position JUMP
    // since last frame (so a widget that moved visually lags, then catches up). Returns the int paint offset.
    fn _flip_axis(mut self, fk: string, solved: int) -> int {
        let lk = fk + ".l"
        let ok = fk + ".o"
        let vk = fk + ".v"
        let s = to_float(solved)
        var last = s                                    // first sight of this key → no jump
        match self.sf.get(lk) {
            case Some(v) { last = v }
            case None {}
        }
        var o = 0.0
        match self.sf.get(ok) {
            case Some(v) { o = v }
            case None {}
        }
        var vel = 0.0
        match self.sf.get(vk) {
            case Some(v) { vel = v }
            case None {}
        }
        o = o - (s - last)                              // counteract the layout jump (keep the visual continuous)
        let force = (0.0 - 170.0 * o) - 26.0 * vel
        vel = vel + force * SPRING_DT
        o = o + vel * SPRING_DT
        var ao = o
        if ao < 0.0 {
            ao = 0.0 - ao
        }
        var av = vel
        if av < 0.0 {
            av = 0.0 - av
        }
        if ao < 0.4 && av < 0.4 {
            o = 0.0
            vel = 0.0
        }
        self.sf.set(lk, s)
        self.sf.set(ok, o)
        self.sf.set(vk, vel)
        return to_int(o)
    }


    // ---- widgets ----
    // _btn is the shared body of button/primary: measure, hit-test against LAST frame's rect (so the
    // click is known now), queue a paint node, and return whether it was clicked.
    fn _btn(mut self, txt: string, kind: int) -> bool {
        let id = self.scope + txt
        let wid = self.ui.wid(txt)
        var padmul = 3
        if kind == _GHOST {            // ghost buttons are compact (a tighter hit/paint box)
            padmul = 2
        }
        let w = measure_text(txt, self.ui.style.text_size) + self.ui.style.pad * padmul
        let h = self.ui.style.row_h
        var clicked = false
        if !(self._modal && !self._in_modal) {       // a modal makes the widgets behind it inert
            match self.rects.get(id) {
                case Some(r) { clicked = self.ui.press(wid, r.x, r.y, r.w, r.h) }
                case None {}
            }
        }
        let node = self.lo.leaf(w, h, 0)
        self._queue(node, kind, txt, id)
        return clicked
    }


    // button is a secondary (panel) action.
    fn button(mut self, txt: string) -> bool {
        return self._btn(txt, _BUTTON)
    }


    // primary is the headline action — filled with the clay accent.
    fn primary(mut self, txt: string) -> bool {
        return self._btn(txt, _PRIMARY)
    }


    // ghost_button is a subtle, borderless action: no fill at rest, a soft hover/press fill, muted ink —
    // for toolbars, message actions (Copy/Retry), and the "···" more-actions affordance.
    fn ghost_button(mut self, txt: string) -> bool {
        return self._btn(txt, _GHOST)
    }


    // nav_item is a full-width sidebar navigation row — a list entry (a chat, a section) that GROWS to fill
    // the panel's width, so it tracks a RESIZABLE sidebar instead of staying a fixed pill, and paints its
    // text LEFT-aligned (the convention for a vertical nav, vs the centred button). `active` gives it the
    // accent fill (the open item). Returns true on click. Pair it in a `row` with a trailing ghost "···"
    // for per-item actions: the nav_item (grow 1) absorbs the free width, the trailing button keeps its own.
    // Needs a STRETCH-aligned parent so the row itself is full-width for the grow to have room.
    fn nav_item(mut self, txt: string, active: bool) -> bool {
        let id = self.scope + "nav/" + txt
        let wid = self.ui.wid("nav/" + txt)
        let h = self.ui.style.row_h
        var clicked = false
        var w_last = 0                              // last frame's painted WIDTH — drives ellipsis-to-fit
        if !(self._modal && !self._in_modal) {
            match self.rects.get(id) {
                case Some(r) {
                    clicked = self.ui.press(wid, r.x, r.y, r.w, r.h)
                    w_last = r.w
                }
                case None {}
            }
        }
        var shown = txt                             // ellipsize the LABEL to the grown width (1-frame lag, like
        if w_last > 0 {                             // text_area's auto-grow) so long titles fill the pill, not 24 chars
            shown = self._fit_text(txt, w_last - self.ui.style.pad * 2)
        }
        var kind = _NAVITEM
        if active {
            kind = _NAVITEM_ON
        }
        let node = self.lo.leaf(0, h, 1)            // base 0 + grow 1 → fills the row; the label is pre-clipped to fit
        self._queue(node, kind, shown, id)
        return clicked
    }


    // _fit_text returns `s` if it already fits `max_px` at the body text size, else the longest leading run that
    // fits WITH a trailing ellipsis — binary-searched over real substring measurements (kerning-correct, ~log n
    // measures). The widget-level "text-overflow: ellipsis": a label too long for its box trims to fit.
    fn _fit_text(self, s: string, max_px: int) -> string {
        let sz = self.ui.style.text_size
        if max_px <= 0 || measure_text(s, sz) <= max_px {
            return s
        }
        let cs = s.chars()
        var lo = 0
        var hi = cs.len()
        loop {                                      // largest n where prefix(n) + "…" fits
            if lo >= hi {
                break
            }
            let mid = (lo + hi + 1) / 2
            var probe: [string] = []
            var i = 0
            loop {
                if i == mid {
                    break
                }
                probe.append(cs[i])
                i = i + 1
            }
            probe.append("…")
            if measure_text(concat(probe), sz) <= max_px {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        var out: [string] = []
        var j = 0
        loop {
            if j == lo {
                break
            }
            out.append(cs[j])
            j = j + 1
        }
        out.append("…")
        return concat(out)
    }


    // segmented is a single-choice control: a row of options, the SELECTED one filled with the clay
    // accent and the rest plain — a model picker, a light/dark switch, a tab strip. Returns the chosen
    // index (the clicked option, or `selected` unchanged), so it reads `idx = f.segmented(...)`. Scope
    // it with `key`; the prior id-scope is preserved, so it nests cleanly inside a keyed list.
    fn segmented(mut self, key: string, options: [string], selected: int) -> int {
        var result = selected
        let save = self.scope
        self.row(START, CENTER)
        var i = 0
        loop {
            if i == options.len() {
                break
            }
            self.key("{save}{key}/{i}")
            var clicked = false
            if i == selected {
                clicked = self.primary(options[i])
            } else {
                clicked = self.button(options[i])
            }
            if clicked {
                result = i
            }
            i = i + 1
        }
        self.end()
        self.scope = save
        self.ui.set_scope(save)
        return result
    }


    // divider draws a full-width hairline rule with a little vertical room — a section separator inside
    // a panel or a settings dialog.
    fn divider(mut self) {
        let node = self.lo.leaf(0, self.ui.style.pad * 2, 0)   // STRETCH align → full width
        self._queue(node, _DIVIDER, "", "")
    }


    // avatar draws a small rounded accent badge with a centred glyph — a chat / identity mark (e.g. the
    // assistant's "*"). Square, sized to the row height; reuse it anywhere a compact identity chip fits.
    fn avatar(mut self, glyph: string) {
        let s = self.ui.style.row_h
        let node = self.lo.leaf(s, s, 0)
        self._queue(node, _AVATAR, glyph, "")
    }


    // bubble_begin opens a rounded, tinted message container — a chat bubble (rounder than panel_begin's
    // structural card, queued before its children so they draw on top). Put a turn's content inside and
    // close with bubble_end(). Reusable for chat turns, comments, callouts.
    fn bubble_begin(mut self) {
        let node = self.lo.open(COL, START, START, self.ui.style.pad, self.ui.style.pad)
        self._queue(node, _BUBBLE, "", "")
    }


    fn bubble_end(mut self) {
        self.lo.close()
    }


    // label is a line of text (left-aligned within its slot).
    fn label(mut self, s: string) {
        let node = self.lo.leaf(measure_text(s, self.ui.style.text_size), self.ui.style.row_h, 0)
        self._queue(node, _LABEL, s, "")
    }


    // text_muted is secondary text (hints, counts) in the muted ink.
    fn text_muted(mut self, s: string) {
        let node = self.lo.leaf(measure_text(s, self.ui.style.text_size), self.ui.style.row_h, 0)
        self._queue(node, _MUTED, s, "")
    }


    // heading is a larger title. Its text is centred within its slot, so a heading placed directly
    // in a STRETCH column fills the width and reads as a centred title, while one in a row stays
    // intrinsic-width (a left-aligned title beside other widgets).
    fn heading(mut self, s: string) {
        let node = self.lo.leaf(measure_text(s, self.ui.style.text_size + 5), self.ui.style.row_h + 8, 0)
        self._queue(node, _HEADING, s, "")
    }


    // paragraph renders multi-line, word-WRAPPED body text within `width` pixels — the transcript's
    // prose widget, and the answer to "f.label is single-line". Each wrapped line is a tightly-stacked
    // label leaf inside a gap-0 column, so a long message flows over as many lines as it needs.
    fn paragraph(mut self, text: string, width: int) {
        let size = self.ui.style.text_size
        let lh = size * 4 / 3                      // tight line height for prose (row_h is too airy)
        let lines = wrap(text, width, size)
        let _ = self.lo.open(COL, START, START, 0, 0)   // gap 0 → lines stack with no inter-line space
        var i = 0
        loop {
            if i == lines.len() {
                break
            }
            let node = self.lo.leaf(measure_text(lines[i], size), lh, 0)
            self._queue(node, _LABEL, lines[i], "")
            i = i + 1
        }
        self.lo.close()
    }


    // _ensure_fonts lazily loads the monospace + italic faces (once a window exists). A missing file
    // yields -1, and the graphics layer then falls back to the body face — so text still renders.
    fn _ensure_fonts(mut self) {
        if self.mono < 0 {
            self.mono = load_font("/System/Library/Fonts/SFNSMono.ttf")
        }
        if self.italic < 0 {
            self.italic = load_font("/System/Library/Fonts/SFNSItalic.ttf")
        }
    }


    // _font_for returns the font slot for a run kind (monospace / italic / the body face for the rest).
    // A slot of -1 (face not loaded) makes the graphics layer fall back to the body face automatically.
    fn _font_for(self, kind: int) -> int {
        if kind == _ICODE {
            return self.mono
        }
        if kind == _EM {
            return self.italic
        }
        return 0
    }


    // rich_text renders a string with inline Markdown emphasis (**bold**, *italic*, `code`, [links]) word-
    // WRAPPED to `width` — the answer to "Claude replies are formatted, not flat". It parses to spans
    // (std/markdown.inline), splits them into words tagged with style + measured in their own face, greedy-
    // wraps, then emits each line as a tight row of run-leaves (consecutive same-style words coalesced into
    // one leaf to keep the node count down). The reusable rich-prose widget; f.markdown drives it.
    fn rich_text(mut self, text: string, width: int) {
        self._ensure_fonts()
        let size = self.ui.style.text_size
        let lh = size * 4 / 3
        // The space between two RUNS must match the space WITHIN a run. A lone measure_text(" ") under-counts
        // (it misses the inter-glyph spacing the renderer adds around a space in real text), which made runs
        // abut with no gap. Derive the true in-context space: measure("a b") − measure("a") − measure("b").
        let space_w = measure_text("a b", size) - measure_text("a", size) - measure_text("b", size)

        // 1) spans → words tagged by style, each measured in its own face.
        let spans = md.inline(text)
        var wt: [string] = []          // word text
        var wk: [int] = []             // word style (doubles as its paint kind)
        var ww: [int] = []             // word width in px (in its face)
        var si = 0
        loop {
            if si == spans.len() {
                break
            }
            var body = ""
            var kind = _LABEL
            match spans[si] {
                case Text(s) {
                    body = s
                }
                case Strong(s) {
                    body = s
                    kind = _BOLD
                }
                case Em(s) {
                    body = s
                    kind = _EM
                }
                case Mono(s) {
                    body = s
                    kind = _ICODE
                }
                case Link(t, u) {
                    body = t
                    kind = _LINK
                }
            }
            set_font(self._font_for(kind))
            let parts = body.split(" ")
            var p = 0
            loop {
                if p == parts.len() {
                    break
                }
                if parts[p].len() > 0 {        // collapse whitespace: spacing comes from the row gap
                    wt.append(parts[p])
                    wk.append(kind)
                    ww.append(measure_text(parts[p], size))
                }
                p = p + 1
            }
            si = si + 1
        }
        set_font(0)

        // 2) greedy-wrap the words; emit each finished line as a row of coalesced run-leaves.
        let _ = self.lo.open(COL, START, START, 0, 0)
        var start = 0
        var i = 0
        var line_w = 0
        loop {
            if i == wt.len() {
                break
            }
            var add = ww[i]
            if i > start {
                add = add + space_w
            }
            if i > start && line_w + add > width {
                self._emit_line(wt, wk, start, i, space_w, lh)
                start = i
                line_w = ww[i]
            } else {
                line_w = line_w + add
            }
            i = i + 1
        }
        if start < wt.len() {
            self._emit_line(wt, wk, start, wt.len(), space_w, lh)
        }
        self.lo.close()
    }


    // _emit_line lays one wrapped line [from,to) of words as a ROW whose gap is one space; a run of same-
    // style words is coalesced into one leaf (cutting node count), the inter-run gap supplying the spaces.
    fn _emit_line(mut self, wt: [string], wk: [int], from: int, to: int, space_w: int, lh: int) {
        let _ = self.lo.open(ROW, START, START, space_w, 0)
        let size = self.ui.style.text_size
        var j = from
        loop {
            if j >= to {
                break
            }
            var seg = wt[j]
            var k = j
            loop {
                if k + 1 >= to {
                    break
                }
                if wk[k + 1] != wk[j] {
                    break
                }
                seg = seg + " " + wt[k + 1]
                k = k + 1
            }
            set_font(self._font_for(wk[j]))      // measure the run in its OWN face, EXACTLY (no width drift)
            let segw = measure_text(seg, size)
            set_font(0)
            let node = self.lo.leaf(segw, lh, 0)
            self._queue(node, wk[j], seg, "")
            j = k + 1
        }
        self.lo.close()
    }


    // _bullet renders a "•" marker beside rich-text body with a hanging indent — the marker column stays
    // fixed while the wrapped body flows beside it. Used by f.markdown for list items.
    fn _bullet(mut self, text: string, width: int) {
        let size = self.ui.style.text_size
        let bw = measure_text("•  ", size) + 4
        let _ = self.lo.open(ROW, START, START, 0, 0)
        let node = self.lo.leaf(bw, size * 4 / 3, 0)
        self._queue(node, _LABEL, "•  ", "")
        self.rich_text(text, width - bw)
        self.lo.close()
    }


    // _hsize is a Markdown heading's pixel size for its level-kind, in one place so build + paint agree.
    fn _hsize(self, kind: int) -> int {
        if kind == _H1 {
            return self.ui.style.text_size + 8
        }
        if kind == _H2 {
            return self.ui.style.text_size + 5
        }
        return self.ui.style.text_size + 3
    }


    // _heading_block renders a Markdown heading: larger, faux-bold, left-aligned, wrapped. Levels 1/2/3+
    // map to _H1/_H2/_H3 (the size steps down). Inline emphasis in a heading is uncommon, so the text is
    // rendered plain at the heading weight (markers stripped).
    fn _heading_block(mut self, text: string, level: int, width: int) {
        var kind = _H1
        if level == 2 {
            kind = _H2
        }
        if level >= 3 {
            kind = _H3
        }
        let hs = self._hsize(kind)
        let lh = hs * 4 / 3
        let lines = wrap(_strip(text), width, hs)
        let _ = self.lo.open(COL, START, START, 0, 0)
        var i = 0
        loop {
            if i == lines.len() {
                break
            }
            let node = self.lo.leaf(measure_text(lines[i], hs), lh, 0)
            self._queue(node, kind, lines[i], "")
            i = i + 1
        }
        self.lo.close()
    }


    // markdown renders a Markdown string (a Claude reply) as a stack of blocks — the rich-text widget.
    // It parses to the Block enum (std/markdown) and a single `match` dispatches each block: prose wraps,
    // quotes get an accent bar, code gets a monospace, syntax-highlighted panel (std/highlight). This is
    // the reusable answer to "code/quote blocks are a repeating pattern" — write it once, any app reuses.
    fn markdown(mut self, text: string, width: int) {
        self._ensure_fonts()
        let blocks = md.parse(text)
        var i = 0
        loop {
            if i == blocks.len() {
                break
            }
            match blocks[i] {
                case Para(t)       { self.rich_text(t, width) }
                case Heading(n, t) { self._heading_block(t, n, width) }
                case Bullet(t)     { self._bullet(t, width) }
                case Quote(t)      { self._quote_block(_strip(t), width) }
                case Table(raw)    { self._table(raw, width) }
                case Code(lang, s) {
                    let bid = "_code{self._mdseq}"            // frame-stable widget id for this block's selection
                    // header bar: language label on the left, a Copy button on the right (like Claude)
                    self.row(BETWEEN, CENTER)
                    self.text_muted(lang)
                    self.key("_cp{self._mdseq}")             // unique id per code block (frame-stable)
                    if self.button("Copy") {
                        clipboard_set(s)
                    }
                    self.key_clear()
                    self._mdseq = self._mdseq + 1
                    self.end()
                    self._code_block(lang, s, width, bid)     // code is verbatim, not stripped
                }
            }
            i = i + 1
        }
    }


    // _code_block reserves a full-width monospace panel sized to the source's line count, and makes its text
    // SELECTABLE: it runs the read-only selection input (drag-select, Ctrl/Cmd+A, Ctrl/Cmd+C) against LAST
    // frame's solved rect — the same input-now/paint-later split the text fields use, so click/keys are known
    // before this frame's layout exists. The _CODE paint node carries the source as its text and a packed
    // "lang\nwidget-id" as its id: the language drives syntax highlighting, the widget id drives the selection.
    fn _code_block(mut self, lang: string, src: string, width: int, blockid: string) {
        let cs = self.ui.style.text_size - 1
        let lh = cs + cs / 2
        let n = src.split("\n").len()
        let h = n * lh + self.ui.style.pad * 2
        let pid = "{lang}\n{blockid}"           // packed paint id: lang (for highlighting) + frame-stable widget id
        match self.rects.get(pid) {             // last frame's solved rect → this frame's input
            case Some(r) {
                var mslot = self.mono
                if mslot < 0 {
                    mslot = 0
                }
                set_font(mslot)                 // mono active so the (mx,my)→caret hit-test matches the glyphs
                self.ui._code_input(hash(blockid), r.x, r.y, r.w, r.h, src, cs, lh, self.ui.style.pad)
                set_font(0)
            }
            case None {}
        }
        let node = self.lo.leaf(width, h, 0)    // explicit width: works in START- *or* STRETCH-aligned parents
        self._queue(node, _CODE, src, pid)
    }




    // _paint_code draws the monospace, syntax-highlighted code panel at its solved rect: a recessed surface,
    // then per line a translucent SELECTION highlight (when this block is the focused selection) drawn behind
    // the highlighted spans so the glyphs sit on top. `pid` is the packed "lang\nwidget-id" — lang feeds the
    // highlighter, the widget id is matched against std/ui's focus to know whether (and where) to highlight.
    fn _paint_code(mut self, src: string, pid: string, x: int, y: int, w: int, h: int) {
        let st = self.ui.style
        let cs = st.text_size - 1
        let lh = cs + cs / 2
        let pad = st.pad
        let parts = pid.split("\n")
        var lang = ""
        var wkey = ""
        if parts.len() > 0 {
            lang = parts[0]
        }
        if parts.len() > 1 {
            wkey = parts[1]
        }
        let focused = self.ui.focus == hash(wkey)
        var lo = self.ui.sel_anchor
        var hi = self.ui.caret
        if lo > hi {
            lo = self.ui.caret
            hi = self.ui.sel_anchor
        }
        let has_sel = focused && lo != hi
        fill_round(x, y, w, h, st.radius, ui.shade(st.bg, 0 - 6), 255)   // recessed surface
        stroke_round(x, y, w, h, st.radius, 1, st.border, 150)
        var mslot = self.mono
        if mslot < 0 {
            mslot = 0
        }
        set_font(mslot)
        clip_push(x, y, w, h)
        let lines = src.split("\n")
        let space_w = measure_text(" ", cs)
        var base = 0
        var li = 0
        loop {
            if li == lines.len() {
                break
            }
            let ly = y + pad + li * lh
            let sx = x + pad
            let cpn = str.cp_count(lines[li])
            let lend = base + cpn
            if has_sel && hi > base && lo <= lend {
                var a = lo
                if a < base {
                    a = base
                }
                var b = hi
                if b > lend {
                    b = lend
                }
                var left = 0
                if a > base {
                    left = measure_text(str.cp_prefix(lines[li], a - base), cs)
                }
                var right = left
                if b > a {
                    right = measure_text(str.cp_prefix(lines[li], b - base), cs)
                }
                if hi > lend {                  // the line's trailing '\n' is selected → a small sliver past it
                    right = right + space_w
                }
                if right > left {
                    fill_round(sx + left, ly, right - left, lh, 0, st.accent, 70)
                }
            }
            let sp = hl.spans(lang, lines[li])
            var gx = sx
            var si = 0
            loop {
                if si == sp.len() {
                    break
                }
                draw_text(sp[si].text, gx, ly, cs, self._code_color(sp[si].kind))
                gx = gx + measure_text(sp[si].text, cs)
                si = si + 1
            }
            base = base + cpn + 1
            li = li + 1
        }
        clip_pop()
        set_font(0)
    }


    // _quote_block pre-wraps the text (indented for the bar) and reserves its height; the _QUOTE paint
    // node draws the accent bar + the muted lines.
    fn _quote_block(mut self, text: string, width: int) {
        let size = self.ui.style.text_size
        let lh = size * 4 / 3
        let indent = self.ui.style.pad * 2
        let lines = wrap(text, width - indent, size)
        var joined = ""
        var i = 0
        loop {
            if i == lines.len() {
                break
            }
            if i > 0 {
                joined = joined + "\n"
            }
            joined = joined + lines[i]
            i = i + 1
        }
        let h = lines.len() * lh + self.ui.style.pad
        let node = self.lo.leaf(width, h, 0)    // explicit width (see _code_block) so quotes never collapse
        self._queue(node, _QUOTE, joined, "")
    }


    // _table renders a Markdown pipe-table as an aligned grid: columns sized to their widest cell, the header
    // row faux-bold with a hairline rule beneath, the body rows below. Reuses the flexbox (a column of rows of
    // cell leaves) — no new paint kinds. Cells are plain (inline emphasis stripped) for v1.
    fn _table(mut self, raw: string, width: int) {
        let size = self.ui.style.text_size
        let lh = size * 4 / 3
        let lines = raw.split("\n")
        var ncols = 0
        var li = 0
        loop {
            if li == lines.len() {
                break
            }
            let cs = _table_cells(lines[li])
            if cs.len() > ncols {
                ncols = cs.len()
            }
            li = li + 1
        }
        if ncols == 0 {
            return
        }
        var colw: [int] = []
        var c = 0
        loop {
            if c == ncols {
                break
            }
            colw.append(0)
            c = c + 1
        }
        li = 0
        loop {
            if li == lines.len() {
                break
            }
            let cs = _table_cells(lines[li])
            var ci = 0
            loop {
                if ci == cs.len() {
                    break
                }
                let cwd = measure_text(_strip(cs[ci]), size) + self.ui.style.pad * 2
                if cwd > colw[ci] {
                    colw[ci] = cwd
                }
                ci = ci + 1
            }
            li = li + 1
        }
        var total = 0
        c = 0
        loop {
            if c == ncols {
                break
            }
            total = total + colw[c]
            c = c + 1
        }
        let _ = self.lo.open(COL, START, START, 0, 0)
        li = 0
        loop {
            if li == lines.len() {
                break
            }
            let cs = _table_cells(lines[li])
            let _ = self.lo.open(ROW, START, START, 0, 0)
            var ci = 0
            loop {
                if ci == ncols {
                    break
                }
                var txt = ""
                if ci < cs.len() {
                    txt = _strip(cs[ci])
                }
                let node = self.lo.leaf(colw[ci], lh, 0)
                var kind = _LABEL
                if li == 0 {
                    kind = _BOLD
                }
                self._queue(node, kind, txt, "")
                ci = ci + 1
            }
            self.lo.close()
            if li == 0 {
                let dn = self.lo.leaf(total, lh / 2, 0)
                self._queue(dn, _DIVIDER, "", "")
            }
            li = li + 1
        }
        self.lo.close()
    }


    // _code_color maps a highlight Kind to a colour (a calm editor palette).
    fn _code_color(self, k: hl.Kind) -> int {
        match k {
            case Keyword { return ui.rgb(198, 120, 221) }   // purple
            case Str     { return ui.rgb(152, 195, 121) }   // green
            case Comment { return ui.rgb(127, 132, 142) }   // grey
            case Number  { return ui.rgb(209, 154, 102) }   // orange
            case Type    { return ui.rgb(86, 182, 194) }    // cyan
            case Plain   { return self.ui.style.ink }
        }
        return self.ui.style.ink
    }


    // text_field is a single-line text input (full std/ui editing: caret, selection, clipboard, scroll).
    // INPUT runs now against LAST frame's solved rect (so click/keys are known before this frame's
    // layout exists); PAINT is deferred to the solved rect. It stretches to fill its slot's width.
    // Returns the current text. Read submit() to see if Enter was pressed in the focused field.
    fn text_field(mut self, key: string, value: string) -> string {
        let id  = self.scope + key
        let wid = self.ui.wid(key)
        var shown = value
        if !(self._modal && !self._in_modal) {       // inert while a modal covers it (no stray focus/typing)
            match self.rects.get(id) {
                case Some(r) {
                    shown = self.ui._tf_edit(wid, r.x, r.y, r.w, r.h, value)
                    if self.ui.focus == wid && key_pressed(KEY_ENTER) {
                        self._submit = true     // report Enter to the caller; do NOT defocus (keep typing)
                    }
                }
                case None {}
            }
        }
        let node = self.lo.leaf(0, self.ui.style.row_h, 0)   // STRETCH align gives it the full width
        self._queue(node, _FIELD, shown, id)
        return shown
    }


    // text_area is a MULTI-LINE editable field that AUTO-GROWS to its content (up to ~8 lines, then scrolls):
    // Shift+Enter inserts a newline, plain Enter is reported via submit() (the composer "send" convention),
    // and it has the full caret/selection/clipboard editing of text_field in 2D. Returns the current text;
    // stretches to fill its slot width. The reusable answer to "the composer is one line" — a real textarea.
    fn text_area(mut self, key: string, value: string) -> string {
        let id  = self.scope + key
        let wid = self.ui.wid(key)
        var shown = value
        if !(self._modal && !self._in_modal) {
            match self.rects.get(id) {
                case Some(r) {
                    shown = self.ui._ta_edit(wid, r.x, r.y, r.w, r.h, value)
                    if self.ui.focus == wid && key_pressed(KEY_ENTER) {
                        if !(key_down(KEY_LSHIFT) || key_down(KEY_RSHIFT)) {   // Shift+Enter = newline (in _ta_edit)
                            self._submit = true
                        }
                    }
                }
                case None {}
            }
        }
        // Auto-grow: height from the wrapped line count at LAST frame's width (1-frame lag, imperceptible).
        var w = 0
        match self.rects.get(id) {
            case Some(r) { w = r.w }
            case None {}
        }
        let lh = text_line_height(self.ui.style.text_size)
        var lines = 1
        let inner = w - self.ui.style.pad * 2
        if inner > 0 {
            lines = self.ui._ta_line_count(shown, inner)
        }
        if lines < 1 {
            lines = 1
        }
        if lines > 8 {
            lines = 8                       // cap the grow; beyond this it scrolls internally
        }
        let hh = lines * lh + self.ui.style.pad * 2
        let node = self.lo.leaf(0, hh, 0)   // STRETCH width, content-driven height
        self._queue(node, _TAREA, shown, id)
        return shown
    }


    // splitter is a draggable resize handle placed BETWEEN two panes; it returns the (maybe updated) size of
    // the pane DECLARED BEFORE IT, so the caller stores the result and feeds it back next frame — the same
    // "value = f.widget(key, value)" idiom as text_field. `vertical` true = a vertical bar inside a row that
    // resizes the WIDTH of the pane to its left (the sidebar case); false = a horizontal bar inside a column
    // that resizes the HEIGHT of the pane above it. `lo`/`hi` clamp the size. Drag it and the panes resize
    // live; the OS cursor becomes a ↔ / ↕ resize arrow while hovering. INPUT runs against LAST frame's rect
    // (1-frame lag, imperceptible), PAINT is deferred — like every Flare widget. Inert under a modal.
    //
    //   var sbw = f.state_int("sbw", 236)
    //   f.panel_begin(START, START); f.strut(sbw, 0); …sidebar…; f.end()
    //   sbw = f.splitter("sb", sbw, 200, 480, true); f.set_int("sbw", sbw)
    //   f.column_grow(START, STRETCH); …main…; f.end()
    fn splitter(mut self, key: string, size: int, lo: int, hi: int, vertical: bool) -> int {
        let id  = self.scope + key
        let wid = self.ui.wid(key)
        var result = size
        if !(self._modal && !self._in_modal) {       // inert while a modal covers the panes
            match self.rects.get(id) {
                case Some(r) {
                    result = self.ui._split_drag(wid, r.x, r.y, r.w, r.h, vertical, true, size, lo, hi)
                }
                case None {}
            }
        } else {
            self.ui.split_release(wid)               // a modal gates the drag → drop any held latch (no jump on resume)
        }
        var node = 0
        var tag = "h"                                // orientation carried in the paint node's text slot (unused
        if vertical {                                // otherwise for _SPLIT), so paint matches the drag axis exactly
            node = self.lo.leaf(HANDLE_W, 0, 0)       // fixed-width bar; STRETCH gives it the row's full height
            tag = "v"
        } else {
            node = self.lo.leaf(0, HANDLE_W, 0)       // fixed-height bar; STRETCH gives it the column's full width
        }
        self._queue(node, _SPLIT, tag, id)
        return result
    }


    // submit returns whether Enter was pressed in a focused text_field this frame — the "user committed
    // this input" signal, kept separate so the field can stay focused across sends. Consuming it also
    // CLEARS the focused field's buffer (Enter = send + clear, the composer behaviour), so the caller's
    // value resets to "" cleanly even though the edit buffer is internal to std/ui.
    fn submit(mut self) -> bool {
        let s = self._submit
        self._submit = false
        if s {
            self.ui.buf = ""
            self.ui.caret = 0
            self.ui.sel_anchor = 0
            self.ui.text_off = 0
        }
        return s
    }


    // _queue records a widget to paint after the solve.
    fn _queue(mut self, node: int, kind: int, text: string, id: string) {
        self.rnode.append(node)
        self.rkind.append(kind)
        self.rtext.append(text)
        self.rid.append(id)
    }


    // _paint draws one widget at its solved rect, in the house style.
    fn _paint(mut self, kind: int, text: string, id: string, x: int, y: int, w: int, h: int) {
        let st = self.ui.style
        if kind == _BUTTON {
            // Secondary button: idle = panel, hover/pressed from the THEME (so hover is visible in the
            // light theme, where panel is white and lightening it does nothing — the reported bug).
            self._paint_button(text, id, x, y, w, h, st.panel, st.hover, st.pressed, st.ink)
        } else if kind == _PRIMARY {
            // Primary: the clay accent has no theme hover/pressed, so derive them by shading.
            self._paint_button(text, id, x, y, w, h, st.accent, ui.shade(st.accent, 14),
                               ui.shade(st.accent, -16), st.accent_ink)
        } else if kind == _NAVITEM {
            self._paint_nav(text, id, x, y, w, h, false)
        } else if kind == _NAVITEM_ON {
            self._paint_nav(text, id, x, y, w, h, true)
        } else if kind == _LABEL {
            draw_text(text, x, y + (h - st.text_size) / 2, st.text_size, st.ink)
        } else if kind == _MUTED {
            draw_text(text, x, y + (h - st.text_size) / 2, st.text_size, st.muted_ink)
        } else if kind == _HEADING {
            let sz = st.text_size + 5
            let tw = measure_text(text, sz)
            var tx = x + (w - tw) / 2
            if tx < x {
                tx = x
            }
            draw_text(text, tx, y + (h - sz) / 2, sz, st.ink)
        } else if kind == _FIELD {
            self.ui._tf_draw(hash(id), x, y, w, h, text)
        } else if kind == _TAREA {
            self.ui._ta_draw(hash(id), x, y, w, h, text)
        } else if kind == _SPLIT {
            // a resize handle: a hairline centred in the wide hit band, brightening on hover / drag. `text`
            // carries the orientation ("v"/"h") set by splitter(), so the line matches the drag axis at any rect.
            let wid = hash(id)
            var col = st.border
            if self.ui.sp_drag == wid {
                col = st.accent
            } else if self.ui.hot == wid {
                col = st.muted_ink
            }
            if text == "v" {                              // vertical bar (resizes width) → a vertical line
                fill_round(x + (w - 1) / 2, y, 1, h, 0, col, 255)
            } else {                                      // horizontal bar (resizes height) → a horizontal line
                fill_round(x, y + (h - 1) / 2, w, 1, 0, col, 255)
            }
        } else if kind == _PANEL {
            ui.card(x, y, w, h, st.panel, st, false)   // surface fill behind the panel's children
        } else if kind == _CODE {
            self._paint_code(text, id, x, y, w, h)
        } else if kind == _QUOTE {
            // a blockquote: an accent bar + indented muted lines (text = pre-wrapped, '\n'-joined)
            let size = st.text_size
            let lh = size * 4 / 3
            let indent = st.pad * 2
            fill_round(x, y, 3, h, 0, st.accent, 200)        // the left accent bar
            let lines = text.split("\n")
            var li = 0
            loop {
                if li == lines.len() {
                    break
                }
                draw_text(lines[li], x + indent, y + li * lh, size, st.muted_ink)
                li = li + 1
            }
        } else if kind == _DIVIDER {
            fill_round(x, y + h / 2, w, 1, 0, st.border, 255)   // a full-width hairline section rule
        } else if kind == _BOLD {
            let ty = y + (h - st.text_size) / 2
            set_font(0)
            draw_text(text, x, ty, st.text_size, st.ink)
            draw_text(text, x + 1, ty, st.text_size, st.ink)   // faux-bold: a second pass 1px right
        } else if kind == _EM {
            let ty = y + (h - st.text_size) / 2
            set_font(self.italic)                              // the italic face (falls back to body if absent)
            draw_text(text, x, ty, st.text_size, st.ink)
            set_font(0)
        } else if kind == _ICODE {
            let ty = y + (h - st.text_size) / 2
            fill_round(x - 2, ty - 2, w + 4, st.text_size + 4, 5, st.track, 255)   // a subtle code chip
            set_font(self.mono)
            draw_text(text, x, ty, st.text_size, st.ink)
            set_font(0)
        } else if kind == _LINK {
            let ty = y + (h - st.text_size) / 2
            draw_text(text, x, ty, st.text_size, st.accent)
            fill_round(x, ty + st.text_size, w, 1, 0, st.accent, 170)   // an underline
        } else if kind == _H1 || kind == _H2 || kind == _H3 {
            let hs = self._hsize(kind)
            let hy = y + (h - hs) / 2
            draw_text(text, x, hy, hs, st.ink)
            draw_text(text, x + 1, hy, hs, st.ink)             // faux-bold heading
        } else if kind == _AVATAR {
            let bs = h                                         // a square badge, sized to the leaf height
            fill_round(x, y, bs, bs, bs / 3, st.accent, 255)
            let gs = st.text_size + 2
            let gw = measure_text(text, gs)
            draw_text(text, x + (bs - gw) / 2, y + (bs - gs) / 2 + 1, gs, st.accent_ink)
        } else if kind == _BUBBLE {
            fill_round(x, y, w, h, st.radius + 4, st.panel, 255)   // a rounder, tinted message card
            stroke_round(x, y, w, h, st.radius + 4, 1, st.border, 120)
        } else if kind == _GHOST {
            let gw = hash(id)                                      // subtle: hover/press fill, no border
            if self.ui.active == gw {
                fill_round(x, y, w, h, st.radius, st.pressed, 255)
            } else if self.ui.hot == gw {
                fill_round(x, y, w, h, st.radius, st.hover, 255)
            }
            let tw = measure_text(text, st.text_size)
            draw_text(text, x + (w - tw) / 2, y + (h - st.text_size) / 2, st.text_size, st.muted_ink)
        } else if kind == _MENUITEM {
            let mw = hash(id)
            var col = st.ink
            if self.ui.hot == mw {                                 // accent highlight on hover (like a menu)
                fill_round(x, y, w, h, 6, st.accent, 255)
                col = st.accent_ink
            }
            draw_text(text, x + st.pad, y + (h - st.text_size) / 2, st.text_size, col)
        }
    }


    // _paint_button draws a card-backed button with centred text: `hover` fill while hovered, `pressed`
    // fill (sunk a pixel) while held — both passed in so each theme/kind picks visible colours (state
    // read from std/ui's hot/active, set during the build pass).
    fn _paint_button(mut self, text: string, id: string, x: int, y: int, w: int, h: int,
                     base: int, hover: int, pressed: int, ink: int) {
        let st = self.ui.style
        let wid = hash(id)
        var fill = base
        var oy = 0
        if self.ui.active == wid {
            fill = pressed
            oy = 1
        } else if self.ui.hot == wid {
            fill = hover
        }
        ui.card(x, y + oy, w, h, fill, st, true)
        let tw = measure_text(text, st.text_size)
        draw_text(text, x + (w - tw) / 2, y + oy + (h - st.text_size) / 2, st.text_size, ink)
    }


    // _paint_nav renders a nav_item: a full-width row with LEFT-aligned text (a left pad), the accent fill
    // when active, else the theme hover/pressed states — the sidebar-list counterpart to centred _paint_button.
    fn _paint_nav(mut self, text: string, id: string, x: int, y: int, w: int, h: int, active: bool) {
        let st = self.ui.style
        let wid = hash(id)
        var base = st.panel
        var hov = st.hover
        var prs = st.pressed
        var ink = st.ink
        if active {
            base = st.accent
            hov = ui.shade(st.accent, 14)
            prs = ui.shade(st.accent, -16)
            ink = st.accent_ink
        }
        var fill = base
        var oy = 0
        if self.ui.active == wid {
            fill = prs
            oy = 1
        } else if self.ui.hot == wid {
            fill = hov
        }
        ui.card(x, y + oy, w, h, fill, st, true)
        draw_text(text, x + st.pad, y + oy + (h - st.text_size) / 2, st.text_size, ink)
    }
}


// new creates a Flare context with the warm Claude light theme. Hold it as a `var`.
fn new() -> Flare {
    return Flare {
        ui: ui.themed(theme_light()),
        si: map.Map<string, int>{ buckets: [], count: 0 },
        ss: map.Map<string, string>{ buckets: [], count: 0 },
        sb: map.Map<string, bool>{ buckets: [], count: 0 },
        sf: map.Map<string, float>{ buckets: [], count: 0 },
        scope: "",
        lo: lay.new(),
        rnode: [], rkind: [], rtext: [], rid: [],
        rects: map.Map<string, Rect>{ buckets: [], count: 0 },
        _submit: false,
        mono: -1,
        italic: -1,
        zoom: 100,
        _mdseq: 0,
        _modal: false,
        _in_modal: false,
        _modal_was: false
    }
}




// A DockTree is a retained, app-owned dock layout: a binary tree of split containers and panel
// leaves, stored as a parallel-array slotmap (one logical node per index, kind 0=free / 1=leaf /
// 2=split). The app holds ONE across frames and mutates it on interaction — split() docks a panel
// beside an existing one, close() removes a panel and collapses its parent split. It is pure data
// (no rendering, no Flare state), so it is headless-testable and serialises cleanly (T7). The
// renderer (T4) walks it to lay panels out; close() returns the removed panel id so the caller can
// dispose that panel's Flare state with f.forget(id), wiring structure (DockTree) to state (Flare).
struct DockTree {
    dk_kind: [int]       // 0 = free slot, 1 = leaf (a panel), 2 = split (two children)
    dk_parent: [int]     // parent node index, -1 for the root
    dk_a: [int]          // split: first child (left / top); leaf: -1
    dk_b: [int]          // split: second child (right / bottom); leaf: -1
    dk_vert: [bool]      // split: true = vertical divider (children side by side), false = stacked
    dk_ratio: [float]    // split: fraction of the main axis given to child A (0..1)
    dk_panel: [string]   // leaf: the panel id; otherwise ""
    dk_x: [int]          // solved rect x (filled by solve(); a node keeps its slot, so rects are stable)
    dk_y: [int]          // solved rect y
    dk_w: [int]          // solved rect width
    dk_h: [int]          // solved rect height
    root: int            // index of the root node, -1 when the tree is empty


    // _alloc returns a node slot set to `kind` with parent `parent`. It reuses the first freed slot
    // (kind 0) or appends a new one, so the arrays never shrink but indices are stable and recycled.
    fn _alloc(mut self, kind: int, parent: int) -> int {
        var idx = -1
        var i = 0
        loop {
            if i == self.dk_kind.len() { break }
            if self.dk_kind[i] == 0 { idx = i  break }
            i = i + 1
        }
        if idx == -1 {
            idx = self.dk_kind.len()
            self.dk_kind.append(0)
            self.dk_parent.append(-1)
            self.dk_a.append(-1)
            self.dk_b.append(-1)
            self.dk_vert.append(false)
            self.dk_ratio.append(0.5)
            self.dk_panel.append("")
            self.dk_x.append(0)
            self.dk_y.append(0)
            self.dk_w.append(0)
            self.dk_h.append(0)
        }
        self.dk_kind[idx]   = kind
        self.dk_parent[idx] = parent
        self.dk_a[idx]      = -1
        self.dk_b[idx]      = -1
        self.dk_vert[idx]   = false
        self.dk_ratio[idx]  = 0.5
        self.dk_panel[idx]  = ""
        return idx
    }


    // _release marks a slot free and drops its panel string, so it can be recycled by _alloc.
    fn _release(mut self, i: int) {
        self.dk_kind[i]   = 0
        self.dk_panel[i]  = ""
        self.dk_a[i]      = -1
        self.dk_b[i]      = -1
        self.dk_parent[i] = -1
    }


    // add_root creates the first panel as the tree root and returns its leaf index. Use only on an
    // empty tree (root == -1); the first panel docked into an app's workspace.
    fn add_root(mut self, panel: string) -> int {
        let i = self._alloc(1, -1)
        self.dk_panel[i] = panel
        self.root = i
        return i
    }


    // split docks `panel` next to an existing `leaf`: a new split node takes `leaf`'s place in the
    // tree, with the old leaf as child A and a new leaf (holding `panel`) as child B. `vertical`
    // chooses a side-by-side (true) or stacked (false) divider; `ratio` is child A's fraction.
    // Returns the new leaf's index. The old leaf keeps its identity (and its panel + state).
    fn split(mut self, leaf: int, panel: string, vertical: bool, ratio: float) -> int {
        let p = self.dk_parent[leaf]
        let s = self._alloc(2, p)
        let nl = self._alloc(1, s)
        self.dk_panel[nl] = panel
        self.dk_a[s]     = leaf
        self.dk_b[s]     = nl
        self.dk_vert[s]  = vertical
        self.dk_ratio[s] = ratio
        self.dk_parent[leaf] = s
        if p == -1 {
            self.root = s
        } else {
            if self.dk_a[p] == leaf {
                self.dk_a[p] = s
            } else {
                self.dk_b[p] = s
            }
        }
        return nl
    }


    // close removes a panel leaf and collapses its parent split (the sibling takes the split's
    // place), returning the removed panel id. Closing the root empties the tree (root == -1). The
    // caller should f.forget(returnedId) to dispose the panel's Flare state.
    fn close(mut self, leaf: int) -> string {
        let panel = self.dk_panel[leaf]
        let p = self.dk_parent[leaf]
        if p == -1 {
            self._release(leaf)
            self.root = -1
            return panel
        }
        var sibling = self.dk_b[p]
        if self.dk_a[p] != leaf {
            sibling = self.dk_a[p]
        }
        let gp = self.dk_parent[p]
        self.dk_parent[sibling] = gp
        if gp == -1 {
            self.root = sibling
        } else {
            if self.dk_a[gp] == p {
                self.dk_a[gp] = sibling
            } else {
                self.dk_b[gp] = sibling
            }
        }
        self._release(leaf)
        self._release(p)
        return panel
    }


    // node_count returns the number of live nodes (leaves + splits) — used to prove no node leaks
    // across a sequence of split/close (an emptied tree must return to 0).
    fn node_count(self) -> int {
        var n = 0
        var i = 0
        loop {
            if i == self.dk_kind.len() { break }
            if self.dk_kind[i] != 0 { n = n + 1 }
            i = i + 1
        }
        return n
    }


    // leaves returns the panel ids of every leaf in left-to-right / top-to-bottom paint order.
    fn leaves(self) -> [string] {
        return self._leaves_from(self.root)
    }


    fn _leaves_from(self, i: int) -> [string] {
        if i < 0 {
            return []
        }
        if self.dk_kind[i] == 1 {
            return [self.dk_panel[i]]
        }
        var out = self._leaves_from(self.dk_a[i])
        let rb = self._leaves_from(self.dk_b[i])
        var j = 0
        loop {
            if j == rb.len() { break }
            out.append(rb[j])
            j = j + 1
        }
        return out
    }


    // solve assigns an absolute rect to every node, top-down: a split divides its rect along its
    // axis by `ratio` (leaving an 8px divider gap), a leaf takes its rect whole. Pure geometry — no
    // input, deterministic — so the layout is headless-testable and the renderer just reads it.
    fn solve(mut self, x: int, y: int, w: int, h: int) {
        self._solve_node(self.root, x, y, w, h)
    }


    fn _solve_node(mut self, i: int, x: int, y: int, w: int, h: int) {
        if i < 0 {
            return
        }
        self.dk_x[i] = x
        self.dk_y[i] = y
        self.dk_w[i] = w
        self.dk_h[i] = h
        if self.dk_kind[i] == 2 {
            let gap = 8
            if self.dk_vert[i] {
                var aw = to_int(to_float(w - gap) * self.dk_ratio[i])
                if aw < 0 { aw = 0 }
                self._solve_node(self.dk_a[i], x, y, aw, h)
                self._solve_node(self.dk_b[i], x + aw + gap, y, w - aw - gap, h)
            } else {
                var ah = to_int(to_float(h - gap) * self.dk_ratio[i])
                if ah < 0 { ah = 0 }
                self._solve_node(self.dk_a[i], x, y, w, ah)
                self._solve_node(self.dk_b[i], x, y + ah + gap, w, h - ah - gap)
            }
        }
    }
}


// dock_new builds an empty DockTree (no panels). Add the first panel with add_root.
fn dock_new() -> DockTree {
    return DockTree {
        dk_kind: [], dk_parent: [], dk_a: [], dk_b: [], dk_vert: [], dk_ratio: [], dk_panel: [],
        dk_x: [], dk_y: [], dk_w: [], dk_h: [],
        root: -1
    }
}
