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
import "std/json" as json


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
let _CLIP_BEGIN = 35   // clip the enclosed widgets to a node's solved rect (a dock panel's content body)
let _CLIP_END   = 36   // close a clip bracket (clip_pop)
let _DANGER = 37        // a destructive-action button — a red fill (delete / remove), like _PRIMARY
let _VITEM  = 38        // a virtualized-list item: a transparent row container whose solved height the paint
                        //  loop records into vrows[] so next frame's window math knows each item's size
let _FADE_BEGIN = 39    // multiply the enclosed widgets' opacity by an amount (the node slot carries 0..255)
let _FADE_END   = 40    // close a fade bracket (restore the parent opacity)
let _MENUBAR_BEGIN = 41 // a full-width top menu-bar strip (bar surface + a bottom hairline), floated at (0,0)
let _MBLABEL    = 42    // a top-bar menu label (File/Edit/…): normal ink over a hover fill
let _MBLABEL_ON = 43    // …the OPEN menu label — a stronger (pressed) fill so it reads as the active menu
let _MENUITEM_A = 44    // a menu row with a right-aligned accelerator ("New chat   ⌘N"); text = "label\taccel"
let _MENU_SEP   = 45    // a thin inset separator rule inside a menu (a grouped divider between item clusters)
let _SUBMENU    = 46    // a menu row that opens a NESTED menu to its right (a trailing "▸" disclosure)
let _SUBMENU_ON = 47    // …the submenu row whose nested menu is currently open (kept highlit)
let _CHECKBOX    = 48   // a pill toggle + trailing label, OFF (text = label)
let _CHECKBOX_ON = 49   // …the toggle ON (accent-filled pill, knob to the right)
let _SLIDER = 50        // a horizontal value track + draggable knob (text = fill permille "0".."1000")
let _DROPDOWN = 51      // a collapsed selector box: left label + right "▾" chevron (opens a popover list)
let _TAB = 52          // a tab chip (inactive): bar fill, muted label, a trailing "×" close zone
let _TAB_ON = 53       // …the active tab chip: panel fill, ink label, an accent underline

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
let KEY_ESC = 256     // Escape — closes an open menu-bar dropdown / command palette
let KEY_DOWN_ = 264   // ↓ — command-palette / typeahead selection down
let KEY_UP_ = 265     // ↑ — command-palette / typeahead selection up
let KEY_TAB = 258     // Tab — accept the highlighted typeahead completion
let MODAL_LAYER = 2000000   // modals draw above everything, including std/ui's menus/tooltips (POPUP_LAYER)


// Rect is a solved widget rectangle (pixel coords). Flare remembers one per interactive widget
// so the NEXT frame's click can hit-test against where the widget actually landed.
struct Rect {
    x: int
    y: int
    w: int
    h: int
}


// VClip is the visible window virtual_begin() returns: build items [start, end) and skip the rest. Mirrors
// Dear ImGui's ListClipper DisplayStart/DisplayEnd.
struct VClip {
    start: int
    end: int
}


// TabResult is what tabs() reports for one frame: `active` is the (maybe changed) selected tab index; `closed`
// is the index whose × was clicked this frame (else -1); `moved_from`/`moved_to` describe a drag-reorder that
// completed this frame (else -1) — the caller applies the move to its own data and the tabs FLIP-animate.
struct TabResult {
    active: int
    closed: int
    moved_from: int
    moved_to: int
}


// ToastItem is one queued toast notification: a stable id (the presence key), its text, the frame it was
// raised (its age drives the auto-dismiss), and an optional action button (label + a token returned when the
// button is clicked, e.g. an "Undo"). See f.toast() / f.toast_action() / f.toast_layer().
struct ToastItem {
    id: int
    text: string
    born: int
    action: string
    token: string
}


// DropHit is where a drag-to-redock release would land: `kind` 0 = nowhere, 1 = beside a panel, 2 = an
// OUTER workspace edge. `panel` is the target panel id (kind 1); `side` is 0 left / 1 right / 2 top / 3
// bottom (the redock()/dock_root_edge() side); (rx,ry,rw,rh) is the preview rectangle the overlay paints
// so the user sees exactly where the panel will go. Computed each frame from the cursor and the solved tree.
struct DropHit {
    kind: int
    panel: string
    side: int
    rx: int
    ry: int
    rw: int
    rh: int
}


// theme_light is the warm "parchment + clay" Claude look — the house default.
fn theme_light() -> ui.Style {
    return ui.Style {
        bg: ui.rgb(244, 242, 237), panel: ui.rgb(255, 255, 255), hover: ui.rgb(243, 240, 235),
        pressed: ui.rgb(232, 228, 221), ink: ui.rgb(38, 36, 32), muted_ink: ui.rgb(124, 120, 112),
        accent: ui.rgb(196, 110, 78), accent_ink: ui.rgb(255, 255, 255),
        danger: ui.rgb(190, 64, 52), danger_ink: ui.rgb(255, 255, 255), border: ui.rgb(212, 207, 198),
        track: ui.rgb(228, 224, 217), bar: ui.rgb(245, 243, 238), radius: 10, pad: 10, gutter: 18, text_size: 19, row_h: 36, shadow: 34
    }
}


// theme_dark is the warm-neutral dark Claude look (same clay accent, lifted for a dark ground).
fn theme_dark() -> ui.Style {
    return ui.Style {
        bg: ui.rgb(38, 38, 36), panel: ui.rgb(46, 46, 43), hover: ui.rgb(58, 58, 54),
        pressed: ui.rgb(54, 54, 50), ink: ui.rgb(237, 234, 228), muted_ink: ui.rgb(150, 147, 139),
        accent: ui.rgb(204, 122, 90), accent_ink: ui.rgb(255, 255, 255),
        danger: ui.rgb(214, 92, 78), danger_ink: ui.rgb(255, 255, 255), border: ui.rgb(58, 57, 53),
        track: ui.rgb(58, 57, 53), bar: ui.rgb(55, 55, 51), radius: 10, pad: 10, gutter: 18, text_size: 19, row_h: 36, shadow: 55
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
    // Per-frame dock geometry: each docked panel's solved CONTENT body rect (the area below its title
    // bar), keyed by panel id. dock_begin() fills it (after springing/snapping each panel); dock_panel()
    // reads it to anchor that panel's content float. Rebuilt every dock_begin, so a closed panel drops out.
    ds: map.Map<string, Rect>
    dpin: [string]                  // panels PINNED this frame (no close ✕ — a permanent anchor); app sets it
                                    // via dock_pin() before dock_begin, which consumes then clears it.
    // Panel-drag latch (drag a title bar to re-dock). pdrag holds the panel id being dragged ("" = none);
    // pox/poy capture the cursor at the press so a move-threshold tells a drag from a plain click. Owned by
    // the Flare layer (the dock is a Flare construct), independent of ui's sp_drag/scroll/window latches.
    pdrag: string
    pox: int
    poy: int
    _submit: bool                   // set when Enter is pressed in a focused text_field; read via submit()
    _rdown: bool                    // right mouse button held THIS frame (mouse_right_down); for right_click()
    _rwas: bool                     // …held LAST frame — the pair gives the right-button down-edge
    _last_wid: int                  // wid of the most-recently hit-tested widget — tooltip() anchors to it
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
    // Set true whenever a spring/FLIP moved this frame (above the at-rest epsilon). The app reads it via
    // is_animating() AFTER finish() to decide whether to keep free-running or settle to event-waiting (idle
    // CPU). Reset each begin(); _spring (build phase) and _flip_axis (paint phase) both raise it.
    _anim: bool
    // Physics sub-steps for this frame = how many fixed 1/60s spring ticks the last frame's wall-time spanned
    // (frame_steps()). 1 at a steady 60fps, more when frames are heavy — so a redock's FLIP runs in real time
    // instead of slow motion. Set in begin(), but ONLY when _realtime is enabled (set_realtime).
    _steps: int
    // Opt-in to wall-clock animation catch-up. OFF by default so the fixed-timestep physics is byte-for-byte
    // DETERMINISTIC (golden-testable, the headless suite depends on it); a real app turns it ON via
    // set_realtime(true) so heavy frames don't drag animations into slow motion. When off, _steps stays 1.
    _realtime: bool
    // Immediate-mode list virtualization (one list per frame — the transcript). vrows persists each item's
    // last-measured height so virtual_begin can place rows without building them; vstart/vend is the window
    // built this frame; _vk counts _VITEM markers in the paint walk to map each back to its row. See
    // virtual_begin(). Restores forrestthewoods's "a single screen's worth is cheap" for unbounded content.
    vrows: [int]
    vcount: int
    vstart: int
    vend: int
    _vk: int
    // Toast notifications: a frame counter (drives each toast's age), the live queue, and the next id. toast()
    // enqueues, toast_layer() renders them as a fade+slide overlay and auto-dismisses by age — built on
    // presence(), so a toast enters and exits with the same spring as everything else. See toast_layer().
    _frame: int
    _toasts: [ToastItem]
    _tnext: int
    _action: string         // token of a toast action clicked THIS frame ("" = none); read via take_action()


    // begin starts a frame: snapshot input, reset the layout tree, open the root column (it fills
    // the window and stretches its children to full width), and clear the paint queue.
    fn begin(mut self) {
        self.ui.begin()
        self.scope = ""
        self.ui.set_scope("")
        self._submit = false
        self._rwas  = self._rdown              // right-button edge tracking (for right_click / context menus)
        self._rdown = mouse_right_down()
        self._last_wid = 0
        self._mdseq = 0
        self._modal = self._modal_was   // a modal was open last frame → gate the background this frame
        self._modal_was = false
        self._in_modal = false
        self._anim = false              // springs/FLIP raise this again if anything moves this frame
        self._action = ""               // a toast action fires for exactly one frame
        self._frame = self._frame + 1   // monotonic frame count (drives toast ages)
        self._steps = 1                 // deterministic fixed timestep by default (golden-stable); set_realtime
        if self._realtime {             // opts into wall-clock catch-up so heavy frames don't slow animations
            self._steps = frame_steps()
        }
        self.lo.reset()
        let pad = self.ui.style.pad
        let _ = self.lo.open(COL, START, STRETCH, pad, self.ui.style.gutter)
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
        var cull = false            // inside a scroll viewport: skip leaves whose rect is FULLY off-screen
        var vtop = 0                // active viewport bounds (screen space) for the cull test
        var vbot = 0
        self._vk = 0                // _VITEM counter: the k-th virtual row painted is item vstart + k
        var ox = 0                  // paint-offset accumulators (f.at / FLIP); a stack so brackets nest
        var oy = 0
        var oxs: [int] = []
        var oys: [int] = []
        var alpha_cur = 255         // active fade opacity (0..255); a stack so fade brackets nest (multiply)
        var alphas: [int] = []
        var layer_cur = 0           // active draw layer; a stack so overlays (modal/popover/submenu) nest —
        var layers: [int] = []      // each _*_BEGIN pushes the current layer and lifts above it, _*_END pops
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
                cull = true              // leaves in this viewport that fall fully outside it are skipped,
                vtop = vy                // not just clipped — a 3000-line message paints only its ~visible
                vbot = vy + vh           // rows, turning O(content) per frame into O(visible).
            } else if kind == _SCROLL_END {
                clip_pop()
                scroll_dy = 0
                cull = false
            } else if kind == _MENUBAR_BEGIN {
                // The top menu-bar strip: a full-width bar surface with a bottom hairline, painted at the
                // float's solved rect (0,0,screen_width,height). Stays on the base layer — it never overlaps
                // the app body (which the app offsets DOWN by menubar_height()); only its dropped menus lift.
                let n  = self.rnode[i]
                let px = self.lo.x(n)
                let py = self.lo.y(n)
                let pw = self.lo.w(n)
                let ph = self.lo.h(n)
                fill_round(px, py, pw, ph, 0, self.ui.style.bar, 255)
                fill_round(px, py + ph - 1, pw, 1, 0, self.ui.style.border, 255)
                self.rects.set(self.rid[i], Rect { x: px, y: py, w: pw, h: ph })   // for next frame's outside-press test
            } else if kind == _MODAL_BEGIN {
                // A floating dialog: lift a layer above the current one (so nested overlays stack), dim the
                // whole window as a scrim, then paint the centred panel surface. Children follow on this layer.
                layers.append(layer_cur)
                layer_cur = self._lift(layer_cur)
                set_layer(layer_cur)
                let n  = self.rnode[i]
                let px = self.lo.x(n)
                let py = self.lo.y(n)
                let pw = self.lo.w(n)
                let ph = self.lo.h(n)
                fill_round(0, 0, screen_width(), screen_height(), 0, ui.rgb(0, 0, 0), 110)
                ui.card(px, py, pw, ph, self.ui.style.panel, self.ui.style, true)
                self.rects.set(self.rid[i], Rect { x: px, y: py, w: pw, h: ph })   // for next frame's scrim hit-test
            } else if kind == _MODAL_END {
                if layers.len() > 0 { layer_cur = layers.remove_at(layers.len() - 1) }
                set_layer(layer_cur)
            } else if kind == _POPOVER_BEGIN {
                // An anchored menu: lift a layer above the current one and paint its raised card — no scrim,
                // so the background stays visible (but inert via the gate). A submenu opened from inside another
                // menu lifts again, so it stacks above its parent; _POPOVER_END pops back to the parent's layer.
                layers.append(layer_cur)
                layer_cur = self._lift(layer_cur)
                set_layer(layer_cur)
                let n  = self.rnode[i]
                let px = self.lo.x(n)
                let py = self.lo.y(n)
                let pw = self.lo.w(n)
                let ph = self.lo.h(n)
                ui.card(px, py, pw, ph, self.ui.style.panel, self.ui.style, true)
                self.rects.set(self.rid[i], Rect { x: px, y: py, w: pw, h: ph })   // for next frame's outside-press test
            } else if kind == _POPOVER_END {
                if layers.len() > 0 { layer_cur = layers.remove_at(layers.len() - 1) }
                set_layer(layer_cur)
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
            } else if kind == _FADE_BEGIN {
                alphas.append(alpha_cur)                 // the 0..255 fade amount rides in the node slot
                alpha_cur = alpha_cur * self.rnode[i] / 255
                set_alpha(alpha_cur)
            } else if kind == _FADE_END {
                if alphas.len() > 0 {
                    alpha_cur = alphas.remove_at(alphas.len() - 1)
                    set_alpha(alpha_cur)
                }
            } else if kind == _CLIP_BEGIN {
                let n = self.rnode[i]                    // clip content to the dock panel's body (the float's rect)
                clip_push(self.lo.x(n) + ox, self.lo.y(n) + oy, self.lo.w(n), self.lo.h(n))
            } else if kind == _CLIP_END {
                clip_pop()
            } else if kind == _VITEM {
                let idx = self.vstart + self._vk         // learn this virtual row's real height for next frame
                if idx < self.vrows.len() {
                    self.vrows[idx] = self.lo.h(self.rnode[i])
                }
                self._vk = self._vk + 1
            } else {
                let n = self.rnode[i]
                let x = self.lo.x(n) + ox
                let y = self.lo.y(n) - scroll_dy + oy
                let w = self.lo.w(n)
                let h = self.lo.h(n)
                // Viewport cull: a leaf entirely above or below the scroll viewport contributes nothing —
                // raylib would clip every pixel, but we'd still have shaped the glyph runs. Skip it outright.
                // The bounds test keeps any leaf that OVERLAPS the viewport (partially-visible rows still paint).
                if !cull || (y + h > vtop && y < vbot) {
                    self._paint(kind, self.rtext[i], self.rid[i], x, y, w, h)
                    if self.rid[i].len() > 0 {
                        self.rects.set(self.rid[i], Rect { x: x, y: y, w: w, h: h })
                    }
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


    // is_animating reports whether any spring or FLIP moved this frame (above the at-rest epsilon). Read it
    // AFTER finish() — FLIP runs during the paint walk — to drive idle frame-gating: while it's true the UI
    // is still in motion and the loop must keep free-running; once it (and input) go quiet the app can settle
    // to event-waiting (set_event_waiting) and stop burning CPU on identical frames.
    fn is_animating(self) -> bool {
        return self._anim
    }


    // set_realtime opts this Flare into wall-clock animation timing: when ON, each frame advances springs/FLIP
    // by however many fixed 1/60s ticks the last frame actually took, so a heavy frame (e.g. a redock that
    // drops to 20fps) catches up instead of playing in slow motion. OFF by default to keep the fixed-timestep
    // physics deterministic for the golden suite — a real app calls set_realtime(true) once at startup.
    fn set_realtime(mut self, on: bool) {
        self._realtime = on
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


    // ---- immediate-mode list virtualization (Dear ImGui ListClipper, adapted) ---------------------------
    // virtual_begin opens a virtualized list INSIDE a scroll viewport: only the rows whose extent falls in
    // the viewport (plus an overscan) are actually built this frame; the skipped rows above and below are
    // replaced by spacer struts of their summed height, so the scroll height, scrollbar and sticky-follow are
    // identical to building everything. Per-row heights are LEARNED from last frame's solved rows (estimated
    // until first seen — react-window's variable-height model), so the window is right after one frame of lag,
    // exactly like Flare's other last-frame reads. Pass the SAME key as the enclosing scroll_begin so it reads
    // that viewport + offset. Returns [start, end): loop i over it, each row inside virtual_item(i)/
    // virtual_item_end(); close with virtual_end(). This turns an unbounded transcript from O(total) work per
    // frame into O(visible) — "a single screen's worth", which is what makes immediate mode cheap.
    fn virtual_begin(mut self, key: string, count: int) -> VClip {
        let est = self._vrow_est()
        loop {                                       // grow the persistent heights to `count` (new rows estimated)
            if self.vrows.len() >= count {
                break
            }
            self.vrows.append(est)
        }
        self.vcount = count

        var total = 0                                // Σ rows == the spacer-filled content height the scroll sees
        var i = 0
        loop {
            if i >= count {
                break
            }
            total = total + self.vrows[i]
            i = i + 1
        }
        let vph = self._si(key + ".vh", 0)           // last frame's viewport height + clamped offset (sticky-safe:
        var overflow = total - vph                   // the 1e6 stick sentinel clamps to the bottom, mirroring finish())
        if overflow < 0 {
            overflow = 0
        }
        var off = self._si(key + ".off", 0)
        if off > overflow {
            off = overflow
        }

        let over = vph / 2 + 1                        // overscan half a viewport each side → no blank on fast scroll
        let top = off - over
        let bot = off + vph + over
        var start = count
        var end = count
        var found = false
        var y = 0
        i = 0
        loop {
            if i >= count {
                break
            }
            let h = self.vrows[i]
            if !found && y + h > top {
                start = i
                found = true
            }
            if found && y >= bot {
                end = i
                break
            }
            y = y + h
            i = i + 1
        }
        if !found {
            start = count                            // viewport past all content (degenerate) → build nothing
        }
        self.vstart = start
        self.vend = end

        var spacer_top = 0                           // summed height of the rows skipped ABOVE the window
        i = 0
        loop {
            if i >= start {
                break
            }
            spacer_top = spacer_top + self.vrows[i]
            i = i + 1
        }
        self.strut(0, spacer_top)
        return VClip { start: start, end: end }
    }


    // virtual_item opens one virtualized row: a transparent full-width container whose SOLVED height the paint
    // walk records into vrows[] (via the _VITEM marker) so next frame's window math knows this row's real size.
    // Build the row's content between this and virtual_item_end().
    fn virtual_item(mut self, i: int) {
        let node = self.lo.open(COL, START, STRETCH, 0, 0)
        self._queue(node, _VITEM, "", "")
    }


    fn virtual_item_end(mut self) {
        self.lo.close()
    }


    // virtual_end closes the list: a final spacer strut for the rows skipped BELOW the window.
    fn virtual_end(mut self) {
        var spacer_bot = 0
        var i = self.vend
        loop {
            if i >= self.vcount {
                break
            }
            spacer_bot = spacer_bot + self.vrows[i]
            i = i + 1
        }
        self.strut(0, spacer_bot)
    }


    // _vrow_est is the height to assume for a not-yet-measured row: the mean of the rows we HAVE measured, so
    // the total height + scrollbar are a sensible guess from the first frame (falls back to ~two text rows).
    fn _vrow_est(self) -> int {
        if self.vrows.len() == 0 {
            return self.ui.style.row_h * 2
        }
        var sum = 0
        var i = 0
        loop {
            if i >= self.vrows.len() {
                break
            }
            sum = sum + self.vrows[i]
            i = i + 1
        }
        return sum / self.vrows.len()
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


    // _lift returns the draw layer one step ABOVE `cur`: the first overlay jumps to MODAL_LAYER (over all
    // base content), and each overlay nested inside another (a submenu off a menu) climbs one more, so it
    // stacks above its parent. The render loop pairs each lift with a pop on the matching _*_END.
    fn _lift(self, cur: int) -> int {
        if cur < MODAL_LAYER {
            return MODAL_LAYER
        }
        return cur + 1
    }


    // ---- menu bar (File / Edit / View …) ----
    // A top-of-window menu strip built on the same floating-node + overlay-gate machinery as the popover.
    // menubar_begin/menubar_end bracket the bar; each menu()/menu_end() declares one dropdown. The bar
    // FLOATS at (0,0) and takes no flow space, so the app offsets its body down by menubar_height().

    // menubar_height is the on-screen height (px) of the bar strip — the amount to inset the app body.
    fn menubar_height(self) -> int {
        return self.ui.style.row_h
    }


    fn _mb_open(self) -> string {
        match self.ss.get("__mb_open") {
            case Some(v) { return v }
            case None {}
        }
        return ""
    }


    // menubar_begin opens the full-width bar pinned to the top of the window. Fill it with menu() blocks.
    fn menubar_begin(mut self) {
        let st = self.ui.style
        let h  = self.menubar_height()
        // Snapshot the open menu + submenu for THIS frame. menu()/submenu() decide what to SHOW from the
        // snapshot, while their click/hover handlers write __mb_open / __mb_sub for NEXT frame. So exactly
        // one menu (and one submenu) is open per frame even mid hover-switch — no same-frame double-open,
        // no two titles lit at once. Input this frame → state next frame, the immediate-mode discipline.
        self.ss.set("__mb_open_f", self._mb_open())
        var sub = ""
        match self.ss.get("__mb_sub") {
            case Some(v) { sub = v }
            case None {}
        }
        self.ss.set("__mb_sub_f", sub)
        let node = self.lo.open_float_at(ROW, START, CENTER, 2, st.pad / 2, 0, 0, screen_width(), h)
        self._queue(node, _MENUBAR_BEGIN, "", "__menubar")
    }


    // menubar_end closes the bar and resolves a click/Esc OUTSIDE the open menu into a close (the caller's
    // menu_item clicks close it directly; this catches presses on empty space and the Escape key).
    fn menubar_end(mut self) {
        self.lo.close()
        var open = self._mb_open()
        if open.len() > 0 {
            if key_pressed(KEY_ESC) {                      // Esc closes the open menu
                open = ""
            } else if self.ui.down && !self.ui.was {       // a press this frame — close unless it landed in the
                var inside = self.ui.my < self.menubar_height()   // bar itself…
                match self.rects.get("mb/pop/" + open) {   // …or inside the open dropdown panel
                    case Some(r) {
                        if self.ui.mx >= r.x && self.ui.mx < r.x + r.w &&
                           self.ui.my >= r.y && self.ui.my < r.y + r.h {
                            inside = true
                        }
                    }
                    case None {}
                }
                if !inside {
                    open = ""
                }
            }
            if open.len() == 0 {
                self.ss.set("__mb_open", "")
                self.ss.set("__mb_sub", "")
            }
        }
    }


    // menu draws one top-bar label and, when its menu is OPEN, drops the panel below it and returns true —
    // the caller then declares the rows and closes with menu_end(). Click a label to toggle it; once any
    // menu is open, moving onto another label switches to it (the familiar menu-bar hover-follow).
    fn menu(mut self, label: string) -> bool {
        let st  = self.ui.style
        let id  = self.scope + "mb/" + label
        let wid = self.ui.wid("mb/" + label)
        let w   = measure_text(label, st.text_size) + st.pad * 2
        let h   = self.menubar_height()
        let open = self._mb_open()               // persistent state (this frame's clicks/hover write it → next frame)
        var shown = ""                           // the snapshot: which menu is open FOR THIS FRAME
        match self.ss.get("__mb_open_f") {
            case Some(v) { shown = v }
            case None {}
        }
        var ax = 0
        var ay = h
        var have = false
        match self.rects.get(id) {
            case Some(r) {
                ax = r.x
                ay = r.y + r.h
                have = true
                if self.ui.press(wid, r.x, r.y, r.w, r.h) {           // click a label → toggle its menu (next frame)
                    if open == label {
                        self.ss.set("__mb_open", "")
                    } else {
                        self.ss.set("__mb_open", label)
                    }
                    self.ss.set("__mb_sub", "")
                } else if open.len() > 0 && open != label {           // a menu is open + hovering another → switch
                    let over = self.ui.mx >= r.x && self.ui.mx < r.x + r.w &&
                               self.ui.my >= r.y && self.ui.my < r.y + r.h
                    if over {
                        self.ss.set("__mb_open", label)
                        self.ss.set("__mb_sub", "")
                    }
                }
            }
            case None {}
        }
        var kind = _MBLABEL
        if shown == label {
            kind = _MBLABEL_ON
        }
        let node = self.lo.leaf_fixed(w, h, 0)
        self._queue(node, kind, label, id)
        if shown == label && have {                                  // OPEN → drop the panel under the label
            self._modal_was = true
            self._in_modal  = true
            self.si.set("__mb_depth", 0)
            let pnode = self.lo.open_float_at(COL, START, STRETCH, 0, st.pad, ax, ay, 0, 0)
            self._queue(pnode, _POPOVER_BEGIN, "", "mb/pop/" + label)
            return true
        }
        return false
    }


    fn menu_end(mut self) {
        self.lo.close()
        self._queue(0, _POPOVER_END, "", "")
        self._in_modal = false
    }


    // menu_item_accel is a menu row with a right-aligned keyboard hint ("New chat   ⌘N"). Behaves exactly
    // like menu_item; the accel text is display-only (bind the real shortcut in your key handling).
    fn menu_item_accel(mut self, txt: string, accel: string) -> bool {
        let st  = self.ui.style
        let id  = self.scope + "mia/" + txt
        let wid = self.ui.wid("mia/" + txt)
        let w   = measure_text(txt, st.text_size) + measure_text(accel, st.text_size) + st.pad * 5
        let h   = st.row_h
        var clicked = false
        if !(self._modal && !self._in_modal) {
            match self.rects.get(id) {
                case Some(r) { clicked = self.ui.press(wid, r.x, r.y, r.w, r.h) }
                case None {}
            }
        }
        if clicked {
            self.ss.set("__mb_open", "")
            self.ss.set("__mb_sub", "")
        } else if self.ui.hot == wid && self._si("__mb_depth", 0) == 0 {
            self.ss.set("__mb_sub", "")                    // moving onto a plain root item collapses a submenu
        }
        // Pack label + accel as one tab-delimited string (the paint splits on the tab). Strip any tab FROM the
        // label/accel first so the split always yields exactly two fields — a stray tab would otherwise leave
        // the accel unrendered and raw tabs in the label.
        let safe  = str.replace(txt, "\t", " ")
        let sacc  = str.replace(accel, "\t", " ")
        let node = self.lo.leaf(w, h, 0)
        self._queue(node, _MENUITEM_A, safe + "\t" + sacc, id)
        return clicked
    }


    // menu_sep is a thin inset rule that groups clusters of menu rows (Cut/Copy/Paste | Select All).
    fn menu_sep(mut self) {
        let node = self.lo.leaf(0, self.ui.style.pad + 2, 0)
        self._queue(node, _MENU_SEP, "", "")
    }


    // submenu is a menu row that opens a NESTED menu to its right (a trailing "▸"). Hover it to expand; the
    // nested panel stays while the cursor is over it or its rows. Fill it like a menu; close with submenu_end().
    fn submenu(mut self, label: string) -> bool {
        let st  = self.ui.style
        let id  = self.scope + "sub/" + label
        let wid = self.ui.wid("sub/" + label)
        let w   = measure_text(label, st.text_size) + st.text_size / 2 + st.pad * 5   // + room for the drawn "▸"
        let h   = st.row_h
        var shown_sub = ""                       // the snapshot: which submenu is open FOR THIS FRAME
        match self.ss.get("__mb_sub_f") {
            case Some(v) { shown_sub = v }
            case None {}
        }
        var ax = 0
        var ay = 0
        var have = false
        if !(self._modal && !self._in_modal) {
            match self.rects.get(id) {
                case Some(r) {
                    let _ = self.ui.press(wid, r.x, r.y, r.w, r.h)     // sets hot for the highlight
                    if self.ui.mx >= r.x && self.ui.mx < r.x + r.w &&
                       self.ui.my >= r.y && self.ui.my < r.y + r.h {
                        self.ss.set("__mb_sub", label)                 // hover opens it NEXT frame (via the snapshot)
                    }
                    ax = r.x + r.w
                    ay = r.y
                    have = true
                }
                case None {}
            }
        }
        let is_open = shown_sub == label && have
        var kind = _SUBMENU
        if is_open {
            kind = _SUBMENU_ON
        }
        let node = self.lo.leaf(w, h, 0)
        self._queue(node, kind, label, id)           // paint draws the "▸" as a vector triangle (font-independent)
        if is_open {
            self.si.set("__mb_depth", self._si("__mb_depth", 0) + 1)
            let pnode = self.lo.open_float_at(COL, START, STRETCH, 0, st.pad, ax, ay, 0, 0)
            self._queue(pnode, _POPOVER_BEGIN, "", "mb/sub/" + label)
            return true
        }
        return false
    }


    fn submenu_end(mut self) {
        self.lo.close()
        self._queue(0, _POPOVER_END, "", "")
        self.si.set("__mb_depth", self._si("__mb_depth", 0) - 1)
    }


    // ---- command palette (⌘K) ----
    // command_palette is a self-contained fuzzy command launcher: a centred modal with a live filter field
    // and a keyboard-navigable list of `commands` (their labels). The app owns an `open` bool and calls this
    // only while open; the widget manages its own query + selection state and AUTO-FOCUSES the field on open,
    // so you start typing without ever clicking it (it accepts input from its first painted frame, the same
    // one-frame settle as every retained-rect widget here — imperceptible at any human typing speed).
    // Returns the chosen command's index into `commands` when one is activated (Enter or click), -1 while it
    // stays open with no choice, or -2 when dismissed (Esc / a press on the scrim). Any value != -1 is the
    // caller's cue to close it: `let p = f.command_palette("cmdk", cmds); if p != -1 { open = false; if p >= 0 { run(cmds[p]) } }`.
    fn command_palette(mut self, key: string, commands: [string]) -> int {
        // Fresh-open detection: if this palette wasn't drawn last frame, it just (re)opened — reset the query
        // and selection and focus the field (no click needed to start typing). self._frame is the monotonic
        // per-frame counter; a gap > 1 means it was closed in between.
        let last = self._si(key + ".seen", 0 - 100)
        let fresh = self._frame - last > 1
        self.si.set(key + ".seen", self._frame)
        if fresh {
            self.ss.set(key + ".q", "")
            self.si.set(key + ".sel", 0)
            self.ui.focus = self.ui.wid(key + "/q")     // auto-focus: drop the caret in the empty filter field
            self.ui.buf = ""
            self.ui.caret = 0
            self.ui.sel_anchor = 0
            self.ui.text_off = 0
        }

        var result = 0 - 1
        let stay = self.modal_begin(key + "/modal", 520, 0)   // h = 0 → sizes to the field + list

        // the live filter field
        var q = ""
        match self.ss.get(key + ".q") {
            case Some(v) { q = v }
            case None {}
        }
        let nq = self.text_field(key + "/q", q)
        if nq != q {
            self.si.set(key + ".sel", 0)                       // typing re-narrows → reset the highlight to the top
        }
        self.ss.set(key + ".q", nq)

        // filter: case-insensitive substring; an empty query lists everything
        let ql = str.to_lower(nq)
        var matches: [int] = []
        var i = 0
        loop {
            if i == commands.len() {
                break
            }
            if ql.len() == 0 || str.contains(str.to_lower(commands[i]), ql) {
                matches.append(i)
            }
            i = i + 1
        }

        // keyboard selection (↑/↓ with wrap), clamped to the current match set
        var sel = self._si(key + ".sel", 0)
        if matches.len() == 0 {
            sel = 0
        } else {
            if key_pressed(KEY_DOWN_) {
                sel = sel + 1
            }
            if key_pressed(KEY_UP_) {
                sel = sel - 1
            }
            if sel < 0 {
                sel = matches.len() - 1
            }
            if sel >= matches.len() {
                sel = 0
            }
        }
        self.si.set(key + ".sel", sel)

        // Enter activates the highlighted match (submit() consumes the flag, so the composer never double-fires)
        if self.submit() && matches.len() > 0 {
            result = matches[sel]
        }

        // the list — rows scoped under `key` so their ids never collide with the app's own nav_items
        let saved = self.scope
        self.key(key)
        if matches.len() == 0 {
            self.text_muted("No matching commands")
        } else {
            var k = 0
            loop {
                if k == matches.len() {
                    break
                }
                let ci = matches[k]
                self.row(START, CENTER)                       // nav_item grows to WIDTH inside a row
                if self.nav_item(commands[ci], k == sel) {
                    result = ci
                }
                self.end()
                k = k + 1
            }
        }
        self.scope = saved
        self.ui.set_scope(saved)

        self.modal_end()

        if key_pressed(KEY_ESC) {
            return 0 - 2
        }
        if !stay {
            return 0 - 2
        }
        return result
    }


    // ---- composer typeahead (slash-commands / @-mentions) ----
    // typeahead is an anchored completion popup for a text field. The caller detects a trigger + partial
    // `query` in its field (e.g. text after a "/" or "@") and passes candidate labels; this filters them
    // (case-insensitive substring), lists them keyboard-navigably in a card ABOVE the field whose key is
    // `anchor`, and returns the accepted candidate's index into `candidates` (Enter / Tab / click), -1 while
    // open with no accept, or -2 when dismissed (Esc). It does NOT gate the field — you keep typing while it
    // filters — and it SWALLOWS the Enter it accepts on (self._submit) so a composer behind it won't also send.
    // The caller owns the text: on a >= 0 return it applies the completion (run a command, insert a mention).
    fn typeahead(mut self, key: string, anchor: string, query: string, candidates: [string]) -> int {
        let st = self.ui.style
        let ql = str.to_lower(query)
        var matches: [int] = []
        var i = 0
        loop {
            if i == candidates.len() {
                break
            }
            if ql.len() == 0 || str.contains(str.to_lower(candidates[i]), ql) {
                matches.append(i)
            }
            i = i + 1
        }
        if matches.len() == 0 {
            // Nothing matches → no popup, and (intentionally) DON'T swallow Enter: with no list showing the
            // field is just normal text, so Enter sends — this is what lets a "/"-prefixed message (e.g. a
            // path like "/etc/hosts", or an unknown "/xyz") be sent as text rather than trapping the caret.
            return 0 - 1
        }
        // selection state, reset the first frame the popup (re)appears (frame gap > 1, like the palette)
        let last = self._si(key + ".seen", 0 - 100)
        let fresh = self._frame - last > 1
        self.si.set(key + ".seen", self._frame)
        var sel = self._si(key + ".sel", 0)
        if fresh {
            sel = 0
        }
        if key_pressed(KEY_DOWN_) {
            sel = sel + 1
        }
        if key_pressed(KEY_UP_) {
            sel = sel - 1
        }
        if sel < 0 {
            sel = matches.len() - 1
        }
        if sel >= matches.len() {
            sel = 0
        }
        self.si.set(key + ".sel", sel)
        if key_pressed(KEY_ESC) {
            return 0 - 2
        }
        var result = 0 - 1
        if key_pressed(KEY_ENTER) || key_pressed(KEY_TAB) {
            result = matches[sel]
            self._submit = false                     // swallow Enter here so the composer's submit() won't fire
        }
        // Position a floating card relative to the anchor field. We need the field's LAST-frame rect; if it
        // isn't known yet (the field was only just added), skip drawing this frame — the keyboard accept above
        // still returns, and the popup appears next frame once the rect exists (no first-frame top-left flash).
        var fx = 0
        var fy = 0
        var fw = 260
        var fh = 0
        var have = false
        match self.rects.get(anchor) {
            case Some(r) {
                fx = r.x
                fy = r.y
                fw = r.w
                fh = r.h
                have = true
            }
            case None {}
        }
        if have {
            let ph = matches.len() * st.row_h + st.pad * 2
            var py = fy - ph - st.pad / 2             // default: just ABOVE the field (a composer sits at the bottom)
            if py < 0 {
                py = fy + fh + st.pad / 2             // not enough room above → drop it BELOW the field instead
            }
            // A NON-gating popover: draw its raised card + rows (reusing the popover paint/layer) but WITHOUT the
            // modal gate, so the field behind stays editable while the list filters live.
            let pnode = self.lo.open_float_at(COL, START, STRETCH, 0, st.pad, fx, py, fw, 0)
            self._queue(pnode, _POPOVER_BEGIN, "", key + ".pop")
            let save = self.scope
            self.key(key)
            var k = 0
            loop {
                if k == matches.len() {
                    break
                }
                let ci = matches[k]
                self.row(START, CENTER)
                if self.nav_item(candidates[ci], k == sel) {
                    result = ci
                }
                self.end()
                k = k + 1
            }
            self.scope = save
            self.ui.set_scope(save)
            self._queue(0, _POPOVER_END, "", "")
            self.lo.close()
        }
        return result
    }


    // ---- checkbox / slider / dropdown ----

    // checkbox is a pill toggle with a trailing label — a boolean setting (Dark mode, Send on Enter …).
    // Pass the current value, get the (maybe flipped) value back: `on = f.checkbox("dark", "Dark mode", on)`.
    // Content-sized (leaf_fixed), so it doesn't span a stretch column.
    fn checkbox(mut self, key: string, label: string, on: bool) -> bool {
        let st  = self.ui.style
        let id  = self.scope + "cb/" + key
        let wid = self.ui.wid("cb/" + key)
        let h   = st.row_h
        let tw  = h + h / 2                                        // the pill track width
        let w   = tw + st.pad + measure_text(label, st.text_size)
        var result = on
        if !(self._modal && !self._in_modal) {
            match self.rects.get(id) {
                case Some(r) {
                    if self.ui.press(wid, r.x, r.y, r.w, r.h) {
                        result = !on
                    }
                }
                case None {}
            }
        }
        var kind = _CHECKBOX
        if result {
            kind = _CHECKBOX_ON
        }
        let node = self.lo.leaf_fixed(w, h, 0)
        self._queue(node, kind, label, id)
        return result
    }


    // slider is a horizontal value track with a draggable knob over the integer range [lo, hi]. Feed the
    // current value, get the dragged value back: `v = f.slider("zoom", v, 60, 220)`. Fills a stretch parent's
    // width (like a text field), so give it a sized row/strut if you want it narrower than the column.
    fn slider(mut self, key: string, value: int, lo: int, hi: int) -> int {
        let st  = self.ui.style
        let id  = self.scope + "sl/" + key
        let wid = self.ui.wid("sl/" + key)
        let h   = st.row_h
        var v = value
        if !(self._modal && !self._in_modal) {
            match self.rects.get(id) {
                case Some(r) {
                    let _ = self.ui.press(wid, r.x, r.y, r.w, r.h)     // hot/active side effects (active = held)
                    if self.ui.active == wid && r.w > 0 {
                        var t = self.ui.mx - r.x
                        if t < 0 {
                            t = 0
                        }
                        if t > r.w {
                            t = r.w
                        }
                        v = lo + (t * (hi - lo) + r.w / 2) / r.w       // map cursor→[lo,hi], rounded (no dead zones)
                    }
                }
                case None {}
            }
        }
        if v < lo {
            v = lo
        }
        if v > hi {
            v = hi
        }
        var permille = 0
        if hi > lo {
            permille = (v - lo) * 1000 / (hi - lo)                     // fill fraction for the paint, carried as text
        }
        let node = self.lo.leaf(200, h, 0)                           // 200px intrinsic; STRETCH grows it to fill
        self._queue(node, _SLIDER, "{permille}", id)
        return v
    }


    // dropdown is a collapsed single-choice selector: a box showing the current option + a "▾" chevron that,
    // on click, drops a popover list of `options`; picking one sets it and closes. Feed the selected index,
    // get the (maybe changed) index back: `i = f.dropdown("model", opts, i)`. The compact alternative to
    // `segmented` when the choices are many or long. Content-sized to the WIDEST option (so it doesn't jump).
    fn dropdown(mut self, key: string, options: [string], selected: int) -> int {
        let st  = self.ui.style
        let id  = self.scope + "dd/" + key
        let wid = self.ui.wid("dd/" + key)
        var maxw = 0
        var i = 0
        loop {
            if i == options.len() {
                break
            }
            let ow = measure_text(options[i], st.text_size)
            if ow > maxw {
                maxw = ow
            }
            i = i + 1
        }
        let w = maxw + st.text_size / 2 + st.pad * 4                  // room for the drawn "▾" chevron
        let h = st.row_h
        var result = selected
        var open = false
        match self.ss.get(id + ".open") {
            case Some(v) { open = v == "1" }
            case None {}
        }
        var bx = 0
        var bty = 0
        var by = 0
        var have = false
        if !(self._modal && !self._in_modal) {
            match self.rects.get(id) {
                case Some(r) {
                    if self.ui.press(wid, r.x, r.y, r.w, r.h) {       // click the box → toggle the list
                        open = !open
                        if open {
                            self.ss.set(id + ".open", "1")
                        } else {
                            self.ss.set(id + ".open", "")
                        }
                    }
                    bx = r.x
                    bty = r.y
                    by = r.y + r.h
                    have = true
                }
                case None {}
            }
        }
        var lbl = ""
        if selected >= 0 && selected < options.len() {
            lbl = options[selected]
        }
        let node = self.lo.leaf_fixed(w, h, 0)
        self._queue(node, _DROPDOWN, lbl, id)
        if open && have {                                            // OPEN → a popover list under the box
            let was_in_modal = self._in_modal                        // may already be inside a modal (settings)
            self._modal_was = true
            self._in_modal  = true
            let pnode = self.lo.open_float_at(COL, START, STRETCH, 0, st.pad, bx, by, w, 0)
            self._queue(pnode, _POPOVER_BEGIN, "", id + ".pop")
            let save = self.scope
            self.key(id)                                            // scope the option rows so ids stay unique
            var j = 0
            loop {
                if j == options.len() {
                    break
                }
                if self.menu_item(options[j]) {
                    result = j
                    self.ss.set(id + ".open", "")                   // pick closes the list
                }
                j = j + 1
            }
            self.scope = save
            self.ui.set_scope(save)
            self._queue(0, _POPOVER_END, "", "")
            self.lo.close()
            self._in_modal = was_in_modal                           // RESTORE — don't clobber an enclosing modal
            // a press OUTSIDE the box and the list closes it (the box toggles itself; this catches elsewhere)
            if self.ui.down && !self.ui.was {
                var inside = self.ui.mx >= bx && self.ui.mx < bx + w &&
                             self.ui.my >= bty && self.ui.my < by       // box's real last-frame span [bty, by)
                match self.rects.get(id + ".pop") {
                    case Some(r) {
                        if self.ui.mx >= r.x && self.ui.mx < r.x + r.w &&
                           self.ui.my >= r.y && self.ui.my < r.y + r.h {
                            inside = true
                        }
                    }
                    case None {}
                }
                if !inside {
                    self.ss.set(id + ".open", "")
                }
            }
        }
        return result
    }


    // ---- tabs ----
    // tabs draws a horizontal strip of closeable tab chips (browser / editor style). Click a chip to SWITCH
    // (the active one is raised to the panel colour with an accent underline); click its trailing "×" to CLOSE
    // it; DRAG a chip left/right to REORDER. It returns a TabResult for this frame — `active` (the maybe-changed
    // selection), `closed` (the ×'d index, else -1), and `moved_from`/`moved_to` (a completed drag-reorder, else
    // -1). The CALLER owns the list: on `closed`/`moved_*` it edits its own array; the chips FLIP-animate to
    // their new slots (each keyed by its label, so the animation follows the tab, not the position).
    fn tabs(mut self, key: string, labels: [string], active: int) -> TabResult {
        let st = self.ui.style
        let scope0 = self.scope
        let h = st.row_h
        let xzone = st.text_size + st.pad                 // the trailing "×" hit/paint zone
        var res_active = active
        var res_closed = 0 - 1
        var res_from = 0 - 1
        var res_to = 0 - 1

        // drag state: which chip is being dragged, the grab x, and whether it has moved past the click threshold
        var drag = self._si(key + ".drag", 0 - 1)
        let grabx = self._si(key + ".grabx", 0)
        var moved = self._si(key + ".moved", 0) == 1
        let mx = self.ui.mx
        let live = !(self._modal && !self._in_modal)
        if drag >= 0 && self.ui.down && (mx - grabx > 6 || grabx - mx > 6) {
            moved = true
            self.si.set(key + ".moved", 1)
        }

        self.row(START, CENTER)
        var i = 0
        loop {
            if i == labels.len() {
                break
            }
            // Hit-test ids are keyed by INDEX (never the label) so DUPLICATE labels can't collide — a click,
            // close, or drag always targets the right chip. FLIP identity below stays label-keyed (so the
            // animation follows a tab across a reorder — that path wants unique labels for a clean slide).
            let id   = scope0 + "{key}/tab/{i}"
            let bwid = self.ui.wid("{key}/tab/{i}")
            let xwid = self.ui.wid("{key}/tabx/{i}")
            let cw = measure_text(labels[i], st.text_size) + st.pad * 2 + xzone
            if live {
                match self.rects.get(id) {
                    case Some(r) {
                        let xz_x = r.x + r.w - xzone
                        if self.ui.press(xwid, xz_x, r.y, xzone, r.h) {          // the × zone → close this tab
                            res_closed = i
                        }
                        if self.ui.pressed_down(bwid, r.x, r.y, r.w - xzone, r.h) {   // down-edge → latch a drag
                            drag = i
                            self.si.set(key + ".drag", i)
                            self.si.set(key + ".grabx", mx)
                            self.si.set(key + ".moved", 0)
                            moved = false
                        }
                    }
                    case None {}
                }
            }
            self.animate_layout(scope0 + key + "/flip/" + labels[i])   // FLIP: slide to the new slot on any change
            var dx = 0
            if drag == i && moved {
                dx = mx - grabx                                        // the dragged chip follows the cursor
            }
            if dx != 0 {
                self.at(to_float(dx), 0.0)
            }
            var kind = _TAB
            if i == active {
                kind = _TAB_ON
            }
            let node = self.lo.leaf_fixed(cw, h, 0)
            self._queue(node, kind, labels[i], id)
            if dx != 0 {
                self.end_at()
            }
            self.end_animate_layout()
            i = i + 1
        }
        self.end()

        // resolve the drag on release: a plain click (no move) SWITCHES; a moved drag REORDERS to the slot whose
        // midpoint the cursor passed.
        if drag >= 0 && !self.ui.down {
            if moved {
                var target = 0
                var j = 0
                loop {
                    if j == labels.len() {
                        break
                    }
                    match self.rects.get(scope0 + "{key}/tab/{j}") {
                        case Some(r) {
                            if mx > r.x + r.w / 2 {
                                target = j + 1
                            }
                        }
                        case None {}
                    }
                    j = j + 1
                }
                if target > drag {
                    target = target - 1                    // account for the dragged tab leaving its old slot
                }
                if target < 0 {
                    target = 0
                }
                if target >= labels.len() {
                    target = labels.len() - 1
                }
                if target != drag {
                    res_from = drag
                    res_to = target
                }
            } else {
                res_active = drag
            }
            self.si.set(key + ".drag", 0 - 1)
            self.si.set(key + ".moved", 0)
        }
        return TabResult { active: res_active, closed: res_closed, moved_from: res_from, moved_to: res_to }
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
        if clicked {                                  // a bar/context menu row → dismiss the menu on click
            self.ss.set("__mb_open", "")
            self.ss.set("__mb_sub", "")
        } else if self.ui.hot == wid && self._si("__mb_depth", 0) == 0 {
            self.ss.set("__mb_sub", "")               // moving onto a plain root item collapses a submenu
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


    // dock_begin lays out and renders a DockTree's CHROME at the given rect, and wires its interaction. It
    // solves the tree, draws every draggable divider (between split children — drag to re-proportion the
    // panes, live), then paints every panel as a themed frame (soft shadow, rounded fill, hairline border,
    // a title bar with a close ✕). Each panel's drawn rect SPRINGS toward its solved target (FLIP), so
    // docking, closing and resizing animate smoothly — EXCEPT during an active divider drag, where the
    // panes SNAP so the resize feels direct (no rubber-banding behind the cursor). It records each panel's
    // content body rect (below the title bar) for dock_panel() to fill. Returns the leaf INDEX whose close
    // button was clicked this frame, or -1; the caller closes it and disposes its state:
    //   let hit = f.dock_begin(tree, x, y, w, h)
    //   if hit >= 0 { let id = tree.close(hit); f.forget(id) }
    //   let ids = tree.leaves()                       // build content for each surviving panel
    //   ... for each id: f.key(id); if f.dock_panel(id) { …widgets… f.dock_panel_end() }
    // Scope is saved/restored so dock_begin is a clean top-level call.
    fn dock_begin(mut self, mut tree: DockTree, x: int, y: int, w: int, h: int) -> int {
        let saved = self.scope
        self.scope = ""
        self.ui.set_scope("")
        tree.solve(x, y, w, h)
        self.ds = map.Map<string, Rect>{ buckets: [], count: 0 }
        let dragging = self._dock_dividers(tree)         // resize handles first → tells the panels whether to snap
        var closed = -1
        var i = 0
        loop {
            if i == tree.dk_kind.len() { break }
            if tree.dk_kind[i] == 1 {
                let pinned = self._dock_pinned(tree.dk_panel[i])
                if self._dock_chrome(tree, i, dragging, pinned) {
                    closed = i
                }
            }
            i = i + 1
        }
        self._dock_drag(tree, x, y, w, h, dragging)      // drag a title bar to re-dock (reads pins → before clear)
        self.dpin = []                                   // pins are per-frame; the app re-asserts them each frame
        self.scope = saved
        self.ui.set_scope(saved)
        return closed
    }


    // dock_pin marks panel `id` as PINNED for the coming dock_begin — it draws no close ✕ and can't be closed
    // by the user (a permanent anchor, e.g. the app's main view). Call it each frame before dock_begin; the
    // pin set is consumed and cleared there, so a panel is only pinned on frames the app actually asks.
    fn dock_pin(mut self, id: string) {
        self.dpin.append(id)
    }


    fn _dock_pinned(self, id: string) -> bool {
        var i = 0
        loop {
            if i == self.dpin.len() { break }
            if self.dpin[i] == id { return true }
            i = i + 1
        }
        return false
    }


    // _dock_dividers walks every split node and renders its draggable boundary, returning whether ANY of
    // them is being actively dragged this frame (so dock_begin can snap the panes for a crisp resize).
    fn _dock_dividers(mut self, mut tree: DockTree) -> bool {
        var dragging = false
        var i = 0
        loop {
            if i == tree.dk_kind.len() { break }
            if tree.dk_kind[i] == 2 {
                if self._dock_divider(tree, i) {
                    dragging = true
                }
            }
            i = i + 1
        }
        return dragging
    }


    // _dock_divider draws split `i`'s resize handle in the 8px gap between its children and applies a drag to
    // its ratio (effective next frame, the standard 1-frame flexbox lag). The hit band straddles the gap; the
    // hairline brightens to the accent while hovered or dragging. Returns true while actively dragged. Inert
    // under a modal (and drops any held latch so the divider can't be carried while the dialog is up).
    fn _dock_divider(mut self, mut tree: DockTree, i: int) -> bool {
        let gap = 8
        let vert = tree.dk_vert[i]
        let sx = tree.dk_x[i]
        let sy = tree.dk_y[i]
        let sw = tree.dk_w[i]
        let sh = tree.dk_h[i]
        let ratio = tree.dk_ratio[i]
        let id = self.ui.wid("dock/div/{i}")
        var cl = 0                                        // divider centre line (x for vertical, y for horizontal)
        var bx = 0
        var by = 0
        var bw = 0
        var bh = 0
        var origin = 0
        var extent = 0
        if vert {
            let aw = to_int(to_float(sw - gap) * ratio)
            cl = sx + aw + gap / 2
            bx = cl - 5  by = sy  bw = 10  bh = sh
            origin = sx  extent = sw - gap
        } else {
            let ah = to_int(to_float(sh - gap) * ratio)
            cl = sy + ah + gap / 2
            bx = sx  by = cl - 5  bw = sw  bh = 10
            origin = sy  extent = sh - gap
        }
        if self._modal && !self._in_modal {
            self.ui.split_release(id)                     // a modal covers the dock → drop the latch, no snap on resume
        } else {
            let nr = self.ui.split_ratio_drag(id, bx, by, bw, bh, vert, origin, extent, ratio)
            tree.dk_ratio[i] = nr
        }
        let active = self.ui.sp_drag == id && self.ui.down
        let st = self.ui.style
        var col = st.border
        var a = 150
        if self.ui.hot == id || active {
            col = st.accent
            a = 235
        }
        if vert {
            fill_round(cl - 1, sy + 8, 2, sh - 16, 1, col, a)
        } else {
            fill_round(sx + 8, cl - 1, sw - 16, 2, 1, col, a)
        }
        return active
    }


    // _dock_chrome paints ONE panel's frame + title bar + close button at its solved target (tx,ty,tw,th),
    // springing the drawn rect toward that target for smooth motion — unless `snap`, where it jumps (a live
    // resize must not lag the divider). It stores the panel's content BODY rect (below the bar) in self.ds
    // for dock_panel(). Returns true if the close ✕ was clicked this frame. The springs are keyed "id/@d*"
    // under the panel's id, so f.forget(id) disposes a closed panel's animation state with the rest.
    fn _dock_chrome(mut self, mut tree: DockTree, i: int, snap: bool, pinned: bool) -> bool {
        let st = self.ui.style
        let id = tree.dk_panel[i]                                     // the leaf's ACTIVE tab
        let tx = tree.dk_x[i]
        let ty = tree.dk_y[i]
        let tw = tree.dk_w[i]
        let th = tree.dk_h[i]
        var px = tx
        var py = ty
        var pw = tw
        var ph = th
        if snap {
            self._spring_set(id + "/@dx", to_float(tx))
            self._spring_set(id + "/@dy", to_float(ty))
            self._spring_set(id + "/@dw", to_float(tw))
            self._spring_set(id + "/@dh", to_float(th))
        } else {
            px = to_int(self.spring(id + "/@dx", to_float(tx)))
            py = to_int(self.spring(id + "/@dy", to_float(ty)))
            pw = to_int(self.spring(id + "/@dw", to_float(tw)))
            ph = to_int(self.spring(id + "/@dh", to_float(th)))
        }
        shadow(px, py + 3, pw, ph, st.radius, st.shadow)
        fill_round(px, py, pw, ph, st.radius, st.panel, 255)
        stroke_round(px, py, pw, ph, st.radius, 1, st.border, 160)
        let bar = st.row_h
        fill_round(px, py, pw, bar, st.radius, st.bar, 255)
        fill_round(px, py + bar - 1, pw, 1, 0, st.border, 150)        // hairline under the bar
        let gate = !(self._modal && !self._in_modal)
        // close ✕ — a square hit area at the bar's right edge; accent-tinted hover, inert under a modal. A
        // PINNED panel draws no ✕. In a tab group the ✕ closes the ACTIVE tab (the leaf survives if more remain).
        var clicked = false
        if !pinned {
            let cw = bar
            let cx = px + pw - cw
            let cid = self.ui.wid("dock/close/{id}")
            if gate {
                clicked = self.ui.press(cid, cx, py, cw, bar)
            }
            var gcol = st.muted_ink
            if self.ui.hot == cid {
                fill_round(cx + 4, py + 4, cw - 8, bar - 8, st.radius, st.hover, 255)
                gcol = st.ink
            }
            let gsz = st.text_size
            // "×" (U+00D7, in the font's Latin-1 subset) — NOT "✕" (U+2715, geometric-shapes block), which
            // tofus to "?" in the embedded body font (same reason menu/dropdown chevrons are drawn, not typed).
            draw_text("×", cx + (cw - measure_text("×", gsz)) / 2, py + (bar - gsz) / 2, gsz, gcol)
        }
        // title — a single panel draws its name; a tab group draws a chip per tab (active raised, click to switch).
        if tree.dk_tabs[i].len() <= 1 {
            draw_text(id, px + st.pad, self._ty(py, bar, st.text_size), st.text_size, st.ink)
        } else {
            self._dock_tabs(tree, i, px, py, bar, gate)
        }
        let cur = tree.dk_panel[i]                                    // a tab click may have changed the active one
        self.ds.set(cur, Rect { x: px, y: py + bar, w: pw, h: ph - bar })
        return clicked
    }


    // _dock_tabs paints a leaf's tab strip — one chip per tab, the active one raised to the panel colour with an
    // accent underline, the rest muted (hover-lit). A press on a chip switches the active tab on the DOWN-EDGE
    // (not release) so the very same press can begin a drag of THAT tab in _dock_drag (which latches the now-active
    // dk_panel afterwards) — drag-a-tab-out falls straight out of it. Inert when `gate` is false (under a modal).
    fn _dock_tabs(mut self, mut tree: DockTree, i: int, px: int, py: int, bar: int, gate: bool) {
        let st = self.ui.style
        let mx = self.ui.mx
        let my = self.ui.my
        var cx = px + st.pad / 2
        var k = 0
        loop {
            if k == tree.dk_tabs[i].len() { break }
            let name = tree.dk_tabs[i][k]
            let cw = measure_text(name, st.text_size) + st.pad * 2
            let active = k == tree.dk_active[i]
            if gate {
                if self.ui.pressed_down(self.ui.wid("dock/tab/{i}/{k}"), cx, py, cw, bar) {
                    tree.set_active(i, k)
                }
            }
            var fillc = st.bar
            var inkc = st.muted_ink
            if active {
                fillc = st.panel
                inkc = st.ink
            } else {
                if mx >= cx && mx < cx + cw && my >= py && my < py + bar {
                    fillc = st.hover
                }
            }
            fill_round(cx + 1, py + 4, cw - 2, bar - 4, st.radius, fillc, 255)
            if active {
                fill_round(cx + 1, py + bar - 2, cw - 2, 2, 0, st.accent, 255)
            }
            draw_text(name, cx + st.pad, self._ty(py, bar, st.text_size), st.text_size, inkc)
            cx = cx + cw + 2
            k = k + 1
        }
    }


    // _spring_set forces a named spring's (position, velocity) to (target, 0) without easing — used to SNAP a
    // value to its target while keeping the spring's state consistent, so motion resumes smoothly afterward.
    fn _spring_set(mut self, key: string, target: float) {
        self.set_float(key + ".sp", target)
        self.set_float(key + ".sv", 0.0)
    }


    // dock_panel opens a content region anchored at panel `id`'s solved body rect (recorded by dock_begin),
    // clipped to it, so the widgets built until dock_panel_end() fill exactly that panel — a floating, full
    // flexbox subtree, so column/row/grow/scroll all work inside. Returns false (build nothing) if `id` is
    // not a live panel this frame. Pair every true return with dock_panel_end(); set the panel's state scope
    // with f.key(id) first so its widget state is panel-local and f.forget(id) disposes it on close.
    fn dock_panel(mut self, id: string) -> bool {
        match self.ds.get(id) {
            case Some(r) {
                let pad = self.ui.style.pad
                let n = self.lo.open_float_at(COL, START, STRETCH, pad, pad, r.x, r.y, r.w, r.h)
                self._queue(n, _CLIP_BEGIN, "", "")
                return true
            }
            case None { return false }
        }
    }


    fn dock_panel_end(mut self) {
        self._queue(0, _CLIP_END, "", "")
        self.lo.close()
    }


    // _dock_drop computes where a drag-to-redock release would land, from the cursor over the SOLVED tree —
    // pure geometry, so the preview the user sees and the mutation that runs come from one source of truth.
    // OUTER edge bands (within `band` px of the workspace boundary) dock against the WHOLE workspace (kind 2)
    // and take precedence over a panel's own edge there; otherwise the leaf under the cursor is classified by
    // dock_zone into a left/right/top/bottom drop (kind 1). A centre-zone hover, a drop onto the dragged panel
    // itself, or the gap between panels yields kind 0 (nothing). (rx,ry,rw,rh) is the preview rectangle.
    fn _dock_drop(self, tree: DockTree, wx: int, wy: int, ww: int, wh: int, mx: int, my: int, dragged: string) -> DropHit {
        let none = DropHit { kind: 0, panel: "", side: 0, rx: 0, ry: 0, rw: 0, rh: 0 }
        if mx < wx { return none }
        if mx >= wx + ww { return none }
        if my < wy { return none }
        if my >= wy + wh { return none }
        let band = 28
        if mx < wx + band {
            return DropHit { kind: 2, panel: "", side: 0, rx: wx, ry: wy, rw: ww * 3 / 10, rh: wh }
        }
        if mx >= wx + ww - band {
            let s = ww * 3 / 10
            return DropHit { kind: 2, panel: "", side: 1, rx: wx + ww - s, ry: wy, rw: s, rh: wh }
        }
        if my < wy + band {
            return DropHit { kind: 2, panel: "", side: 2, rx: wx, ry: wy, rw: ww, rh: wh * 3 / 10 }
        }
        if my >= wy + wh - band {
            let s = wh * 3 / 10
            return DropHit { kind: 2, panel: "", side: 3, rx: wx, ry: wy + wh - s, rw: ww, rh: s }
        }
        var i = 0
        loop {
            if i == tree.dk_kind.len() { break }
            if tree.dk_kind[i] == 1 {
                let px = tree.dk_x[i]
                let py = tree.dk_y[i]
                let pw = tree.dk_w[i]
                let ph = tree.dk_h[i]
                if mx >= px && mx < px + pw && my >= py && my < py + ph {
                    let id = tree.dk_panel[i]
                    if id == dragged { return none }       // never preview a drop onto the panel you're dragging
                    let z = dock_zone(px, py, pw, ph, mx, my)
                    if z == 0 {
                        return DropHit { kind: 1, panel: id, side: 0, rx: px, ry: py, rw: pw * 4 / 10, rh: ph }
                    }
                    if z == 1 {
                        let s = pw * 4 / 10
                        return DropHit { kind: 1, panel: id, side: 1, rx: px + pw - s, ry: py, rw: s, rh: ph }
                    }
                    if z == 2 {
                        return DropHit { kind: 1, panel: id, side: 2, rx: px, ry: py, rw: pw, rh: ph * 4 / 10 }
                    }
                    if z == 3 {
                        let s = ph * 4 / 10
                        return DropHit { kind: 1, panel: id, side: 3, rx: px, ry: py + ph - s, rw: pw, rh: s }
                    }
                    return DropHit { kind: 1, panel: id, side: 4, rx: px, ry: py, rw: pw, rh: ph }  // centre → tabify
                }
            }
            i = i + 1
        }
        return none
    }


    // _dock_drag runs the drag-a-title-bar-to-redock interaction for one frame. It latches a press on a panel's
    // title bar (minus its close ✕), and once the cursor moves past a small threshold it shows a grab cursor, a
    // ghost chip at the pointer, and the live drop preview; on release it re-docks via redock()/dock_root_edge().
    // INERT under a modal and skipped while a divider is being dragged (the two latches can't coexist). The press
    // down-edge is consumed here, so no panel-content widget can claim a click mid-drag (immediate mode: a widget
    // grabs `active` on the down-edge, which has already passed — so the drag is naturally modal, no extra gate).
    fn _dock_drag(mut self, mut tree: DockTree, wx: int, wy: int, ww: int, wh: int, divider_dragging: bool) {
        if self._modal && !self._in_modal {
            self.pdrag = ""                                // a modal covers the dock → abandon any drag
            return
        }
        if divider_dragging {
            self.pdrag = ""
            return
        }
        let mx = self.ui.mx
        let my = self.ui.my
        let down = self.ui.down
        let st = self.ui.style
        let bar = st.row_h

        if self.pdrag == "" {
            var i = 0
            loop {
                if i == tree.dk_kind.len() { break }
                if tree.dk_kind[i] == 1 {
                    let px = tree.dk_x[i]
                    let py = tree.dk_y[i]
                    var bw = tree.dk_w[i]
                    if !self._dock_pinned(tree.dk_panel[i]) {
                        bw = bw - bar                       // leave the ✕ hit area to the close button
                    }
                    if bw < 0 { bw = 0 }
                    let hid = self.ui.wid("dock/bar/{tree.dk_panel[i]}")
                    if self.ui.pressed_down(hid, px, py, bw, bar) {
                        self.pdrag = tree.dk_panel[i]
                        self.pox = mx
                        self.poy = my
                    }
                }
                i = i + 1
            }
            return                                          // the press frame just latches; the drag begins on move
        }

        var ddx = mx - self.pox
        if ddx < 0 { ddx = -ddx }
        var ddy = my - self.poy
        if ddy < 0 { ddy = -ddy }
        let moved = ddx > 6 || ddy > 6
        let dragged = self.pdrag

        if !down {
            if moved {
                let hit = self._dock_drop(tree, wx, wy, ww, wh, mx, my, dragged)
                if hit.kind == 1 {
                    tree.redock(dragged, hit.panel, hit.side)
                } else {
                    if hit.kind == 2 {
                        tree.dock_root_edge(dragged, hit.side)
                    }
                }
            }
            self.pdrag = ""
            return
        }

        if !moved {
            return                                          // still within the click threshold — no ghost yet
        }

        set_cursor(3)                                       // CURSOR_HAND (std/ui) — the grab affordance
        let hit = self._dock_drop(tree, wx, wy, ww, wh, mx, my, dragged)
        set_layer(MODAL_LAYER - 1)
        if hit.kind != 0 {
            fill_round(hit.rx, hit.ry, hit.rw, hit.rh, st.radius, st.accent, 60)
            stroke_round(hit.rx, hit.ry, hit.rw, hit.rh, st.radius, 2, st.accent, 220)
        }
        let gw = measure_text(dragged, st.text_size) + st.pad * 2
        let gx = mx + 12
        let gy = my + 8
        shadow(gx, gy + 2, gw, bar, st.radius, st.shadow)
        fill_round(gx, gy, gw, bar, st.radius, st.accent, 235)
        draw_text(dragged, gx + st.pad, self._ty(gy, bar, st.text_size), st.text_size, st.accent_ink)
        set_layer(0)
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


    // enter returns a 0 → 1 "appearance" progress for a KEYED element: the first frame its key is seen it
    // starts at 0 and springs to 1, every frame after it is already ~1 (no re-trigger). This is the immediate-
    // mode answer to React's <AnimatePresence> enter — it needs nothing but keyed-state (a key with no stored
    // progress IS a first appearance). Ride it with at()/fade for a slide/fade-in:
    //   let e = f.enter("msg" + id); f.at(0.0, (1.0 - e) * 24.0); ...render...; f.end_at()
    // NOTE under virtualization, apply it only to GENUINELY-new items (the latest message), not every list row
    // — a row's "first sight" is when it first scrolls into view, which you don't want to animate.
    fn enter(mut self, key: string) -> float {
        let pk = self.scope + key + ".enp"
        let vk = self.scope + key + ".env"
        var pos = self.state_float(pk, 0.0)                 // FIRST sight → 0 (the origin), springs toward 1
        var vel = self.state_float(vk, 0.0)
        var n = self._steps
        loop {
            if n == 0 {
                break
            }
            let force = (0.0 - 200.0 * (pos - 1.0)) - 26.0 * vel
            vel = vel + force * SPRING_DT
            pos = pos + vel * SPRING_DT
            n = n - 1
        }
        var adp = pos - 1.0                                 // fine thresholds: this is a 0..1 progress, not pixels
        if adp < 0.0 {
            adp = 0.0 - adp
        }
        var av = vel
        if av < 0.0 {
            av = 0.0 - av
        }
        if adp < 0.004 && av < 0.01 {
            pos = 1.0
            vel = 0.0
        } else {
            self._anim = true
        }
        self.set_float(pk, pos)
        self.set_float(vk, vel)
        return pos
    }


    // presence is enter AND exit in one — the immediate-mode <AnimatePresence>. It returns a 0..1 progress that
    // springs to 1 while `present` is true (a first-seen key starts at 0, so it animates IN) and back to 0 once
    // `present` goes false (it animates OUT). Keep rendering a leaving item until presence returns ~0, THEN drop
    // it from your data — that's the whole exit lifecycle, with nothing but keyed-state:
    //   let p = f.presence("row:" + id, !leaving)
    //   f.at(0.0, (1.0 - p) * 16.0); ...render the row...; f.end_at()
    //   if leaving && p < 0.02 { actually_remove(id) }   // exit finished
    fn presence(mut self, key: string, present: bool) -> float {
        let pk = self.scope + key + ".prp"
        let vk = self.scope + key + ".prv"
        var pos = self.state_float(pk, 0.0)                 // first sight → 0 → springs in
        var vel = self.state_float(vk, 0.0)
        var target = 0.0
        if present {
            target = 1.0
        }
        var n = self._steps
        loop {
            if n == 0 {
                break
            }
            let force = (0.0 - 200.0 * (pos - target)) - 26.0 * vel
            vel = vel + force * SPRING_DT
            pos = pos + vel * SPRING_DT
            n = n - 1
        }
        var adp = pos - target
        if adp < 0.0 {
            adp = 0.0 - adp
        }
        var av = vel
        if av < 0.0 {
            av = 0.0 - av
        }
        if adp < 0.004 && av < 0.01 {
            pos = target
            vel = 0.0
        } else {
            self._anim = true
        }
        self.set_float(pk, pos)
        self.set_float(vk, vel)
        return pos
    }


    fn _spring(mut self, key: string, target: float, k: float, c: float) -> float {
        let pk = key + ".sp"
        let vk = key + ".sv"
        var pos = self.state_float(pk, target)              // unseen key → snap to target (no jump-from-zero)
        var vel = self.state_float(vk, 0.0)
        var n = self._steps                                  // real-time catch-up: one tick per 1/60s elapsed,
        loop {                                               // so a heavy frame advances the spring further
            if n == 0 {
                break
            }
            let force = (0.0 - k * (pos - target)) - c * vel // F = -k·x - c·v
            vel = vel + force * SPRING_DT                    // semi-implicit Euler (update v, then x with new v)
            pos = pos + vel * SPRING_DT
            n = n - 1
        }
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
        } else {
            self._anim = true                                // still moving → keep the loop free-running
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


    // fade_begin multiplies the opacity of every widget built between it and fade_end() by `amount` (0..1) —
    // a whole subtree fades as one (text, fills, shadows). Pure paint, no layout effect; brackets nest
    // (multiply). Pair with enter()/presence() for fade-in/out, or a constant for dimming a disabled region:
    //   let p = f.presence(key, !leaving); f.fade_begin(p); f.at(0.0, (1.0-p)*16.0); ...; f.end_at(); f.fade_end()
    fn fade_begin(mut self, amount: float) {
        var a = to_int(amount * 255.0)
        if a < 0 {
            a = 0
        }
        if a > 255 {
            a = 255
        }
        self._queue(a, _FADE_BEGIN, "", "")     // the 0..255 amount rides in the node slot
    }


    fn fade_end(mut self) {
        self._queue(0, _FADE_END, "", "")
    }


    // toast raises a transient notification — a pill that slides + fades in at the bottom of the window, holds
    // a few seconds, then auto-dismisses. Call it from anywhere (a click handler, an error path); the queue is
    // drawn once per frame by toast_layer(). Built on presence(), so a toast enters and leaves with the house
    // spring, and the dismiss is a deterministic frame count.
    fn toast(mut self, text: string) {
        self._toasts.append(ToastItem { id: self._tnext, text: text, born: self._frame, action: "", token: "" })
        self._tnext = self._tnext + 1
    }


    // toast_action raises a toast with a clickable action button (e.g. "Undo"). When the button is pressed,
    // take_action() returns `token` for one frame (and the toast dismisses). The canonical reversible-action
    // pattern: do the action immediately, show "Done · Undo", and roll it back if the token comes back.
    fn toast_action(mut self, text: string, action: string, token: string) {
        self._toasts.append(ToastItem { id: self._tnext, text: text, born: self._frame, action: action, token: token })
        self._tnext = self._tnext + 1
    }


    // take_action returns (and clears) the token of a toast action clicked this frame, or "" if none. Poll it
    // once per frame: `if f.take_action() == "undo_delete" { ... }`.
    fn take_action(mut self) -> string {
        let t = self._action
        self._action = ""
        return t
    }


    // toast_layer draws + ages the toast queue: each pill enters (presence 0→1: fade + slide up), holds for
    // ~3.3s, then exits (presence → 0) and is dropped. Call it ONCE per frame, AFTER finish() — it draws
    // directly on the modal layer, above the UI. While any toast is alive it keeps the loop awake (so the age
    // timer and the exit keep advancing even under idle event-waiting). Stacks newest at the bottom.
    fn toast_layer(mut self) {
        if self._toasts.len() == 0 {
            return
        }
        let st = self.ui.style
        set_layer(MODAL_LAYER)
        var keep: [ToastItem] = []
        var slot = 0
        var i = 0
        loop {
            if i >= self._toasts.len() {
                break
            }
            let t = self._toasts[i]
            let present = self._frame - t.born < 200          // ~3.3s at 60fps before it begins to leave
            let p = self.presence("_toast{t.id}", present)
            if present || p > 0.02 {
                self._anim = true                             // keep the loop awake so age + exit keep ticking
                let tw = measure_text(t.text, st.text_size)
                var aw = 0                                    // action button width (0 = a plain toast)
                if t.action.len() > 0 {
                    aw = measure_text(t.action, st.text_size) + st.pad * 2
                }
                let pw = tw + st.pad * 3 + aw
                let ph = st.text_size + st.pad * 2 + 4
                let px = (screen_width() - pw) / 2
                let py = screen_height() - 60 - slot * (ph + 10)
                let ty = py + to_int((1.0 - p) * 18.0)
                let ax = px + pw - aw - st.pad                // action button's left edge (right-aligned in the pill)

                var dismissed = false                         // a release over the action button fires its token + closes it
                if aw > 0 && self.ui.was && !self.ui.down && self.ui.mx >= ax && self.ui.mx < px + pw && self.ui.my >= ty && self.ui.my < ty + ph {
                    self._action = t.token
                    dismissed = true
                }

                set_alpha(to_int(p * 255.0))                  // the whole pill fades with the presence value
                fill_round(px, ty, pw, ph, st.radius, st.ink, 255)
                stroke_round(px, ty, pw, ph, st.radius, 1, st.border, 90)
                draw_text(t.text, px + (pw - aw - tw) / 2, self._ty(ty, ph, st.text_size), st.text_size, st.panel)
                if aw > 0 {
                    fill_round(ax, ty + 4, aw, ph - 8, st.radius - 2, st.accent, 255)
                    let alw = measure_text(t.action, st.text_size)
                    draw_text(t.action, ax + (aw - alw) / 2, self._ty(ty + 4, ph - 8, st.text_size), st.text_size, st.accent_ink)
                }
                set_alpha(255)

                if !dismissed {
                    keep.append(t)
                    slot = slot + 1
                }
            }
            i = i + 1
        }
        self._toasts = keep
        set_layer(0)
    }


    // toast_count is how many toasts are still alive (entering, held, or exiting) — 0 once the queue is clear.
    fn toast_count(self) -> int {
        return self._toasts.len()
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
        var n = self._steps                             // real-time catch-up (matches _spring) so the FLIP
        loop {                                          // a redock kicks off runs in wall-clock time, not frames
            if n == 0 {
                break
            }
            let force = (0.0 - 170.0 * o) - 26.0 * vel
            vel = vel + force * SPRING_DT
            o = o + vel * SPRING_DT
            n = n - 1
        }
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
        } else {
            self._anim = true                                // FLIP still in flight → keep the loop free-running
        }
        self.sf.set(lk, s)
        self.sf.set(ok, o)
        self.sf.set(vk, vel)
        return to_int(o)
    }


    // ---- widgets ----
    // _btn is the shared body of button/primary: measure, hit-test against LAST frame's rect (so the
    // click is known now), queue a paint node, and return whether it was clicked.
    fn _btn(mut self, txt: string, kind: int, fill: bool) -> bool {
        let id = self.scope + txt
        let wid = self.ui.wid(txt)
        self._last_wid = wid                    // so a following tooltip() / right_clicked() can anchor here
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
        // An atomic action widget sizes to its CONTENT by default (leaf_fixed), so a bare button in the
        // default stretch column no longer spans the whole window (OFI-115). `fill` opts back into the
        // full-width behaviour for a deliberate block CTA (e.g. a sidebar "New chat").
        var node = 0
        if fill {
            node = self.lo.leaf(w, h, 0)
        } else {
            node = self.lo.leaf_fixed(w, h, 0)
        }
        self._queue(node, kind, txt, id)
        return clicked
    }


    // button is a secondary (panel) action — content-sized.
    fn button(mut self, txt: string) -> bool {
        return self._btn(txt, _BUTTON, false)
    }


    // primary is the headline action — filled with the clay accent; content-sized.
    fn primary(mut self, txt: string) -> bool {
        return self._btn(txt, _PRIMARY, false)
    }


    // danger is the DESTRUCTIVE action — filled with the theme's red (Delete, Remove, Discard). Same
    // shape as primary; the colour is the only signal, so reach for it only when the action is hard to undo.
    fn danger(mut self, txt: string) -> bool {
        return self._btn(txt, _DANGER, false)
    }


    // ghost_button is a subtle, borderless action: no fill at rest, a soft hover/press fill, muted ink —
    // for toolbars, message actions (Copy/Retry), and the "···" more-actions affordance.
    fn ghost_button(mut self, txt: string) -> bool {
        return self._btn(txt, _GHOST, false)
    }


    // button_fill / primary_fill are the FULL-WIDTH variants — they fill a stretch parent's cross axis
    // (a block button spanning a column), for a deliberate primary CTA or a stacked list of choices.
    fn button_fill(mut self, txt: string) -> bool {
        return self._btn(txt, _BUTTON, true)
    }


    fn primary_fill(mut self, txt: string) -> bool {
        return self._btn(txt, _PRIMARY, true)
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
        self._last_wid = wid                    // so a following tooltip() / right_clicked() can anchor here
        let h = self.ui.style.row_h
        var clicked = false
        var w_last = 0                              // last frame's painted WIDTH — drives ellipsis-to-fit
        match self.rects.get(id) {                  // read the width ALWAYS, even when the background is inert
            case Some(r) {
                w_last = r.w                         // so the title keeps ellipsizing while a popover/modal is open
                if !(self._modal && !self._in_modal) {   // ...but suppress the CLICK there (no fall-through)
                    clicked = self.ui.press(wid, r.x, r.y, r.w, r.h)
                }
            }
            case None {}
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
        return self._fit_text_sz(s, max_px, self.ui.style.text_size)
    }


    // _fit_text_sz is _fit_text at an explicit text size — headings measure larger than body text, so
    // the ellipsis fit has to use the size the text is actually drawn at.
    fn _fit_text_sz(self, s: string, max_px: int, sz: int) -> string {
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
                        self.toast("Copied to clipboard")
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


    // clear_field resets the FOCUSED text field's live edit buffer to empty — call it after you've
    // programmatically replaced the field's text (e.g. a typeahead completion consumed the input), so the
    // on-screen field matches the new value instead of the stale keystrokes still held in the editor buffer.
    fn clear_field(mut self) {
        self.ui.buf = ""
        self.ui.caret = 0
        self.ui.sel_anchor = 0
        self.ui.text_off = 0
    }


    // ---- right-click / tooltip ----

    // right_click reports the RIGHT mouse button's down-edge this frame (pressed now, up last frame) — a
    // right-click anywhere. Pair with a hit-test, or use right_clicked() to scope it to the last widget.
    fn right_click(self) -> bool {
        return self._rdown && !self._rwas
    }


    // right_clicked reports a right-click on the MOST-RECENTLY-drawn interactive widget (a button / nav_item /
    // tab): call it immediately after that widget. True once, on the down-edge, while the cursor is over it —
    // the hook for a right-click context menu (open a popover at the cursor). Returns false while a modal gates.
    fn right_clicked(self) -> bool {
        if self._modal && !self._in_modal {
            return false
        }
        return self.right_click() && self._last_wid != 0 && self.ui.hot == self._last_wid
    }


    // tooltip shows a small hint near the cursor after the MOST-RECENTLY-drawn widget has been hovered for a
    // short delay (~0.4s). Call it right after the widget: `if f.ghost_button("⧉") {…}  f.tooltip("Copy")`.
    // A single timer suffices (only one widget is hovered at a time); it rests on the same floating card as
    // the popover, on a raised layer, and never gates the UI.
    fn tooltip(mut self, text: string) {
        if self._last_wid == 0 || self.ui.hot != self._last_wid {
            return
        }
        var age = 1
        if self._si("__tip_wid", 0) == self._last_wid {
            age = self._si("__tip_age", 0) + 1
        }
        self.si.set("__tip_wid", self._last_wid)
        self.si.set("__tip_age", age)
        if age < 24 {                                     // ~0.4s dwell before it appears
            return
        }
        let st = self.ui.style
        let tx = self.ui.mx + 14
        let ty = self.ui.my + 18
        let pnode = self.lo.open_float_at(COL, START, START, 0, st.pad, tx, ty, 0, 0)
        self._queue(pnode, _POPOVER_BEGIN, "", "__tip")
        let w = measure_text(text, st.text_size)
        let lnode = self.lo.leaf_fixed(w, st.text_size + st.pad / 2, 0)
        self._queue(lnode, _LABEL, text, "")
        self._queue(0, _POPOVER_END, "", "")
        self.lo.close()
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
        } else if kind == _DANGER {
            // Destructive: the danger red, hover/pressed derived by shading (like primary).
            self._paint_button(text, id, x, y, w, h, st.danger, ui.shade(st.danger, 14),
                               ui.shade(st.danger, -16), st.danger_ink)
        } else if kind == _NAVITEM {
            self._paint_nav(text, id, x, y, w, h, false)
        } else if kind == _NAVITEM_ON {
            self._paint_nav(text, id, x, y, w, h, true)
        } else if kind == _LABEL {
            // text-overflow: ellipsis — a single-line label too wide for its solved box trims to fit
            // (the box is its full width in a row, or the column width when stretched) rather than
            // spilling off-screen.
            draw_text(self._fit_text(text, w), x, y + (h - st.text_size) / 2, st.text_size, st.ink)
        } else if kind == _MUTED {
            draw_text(self._fit_text(text, w), x, y + (h - st.text_size) / 2, st.text_size, st.muted_ink)
        } else if kind == _HEADING {
            let sz = st.text_size + 5
            let shown = self._fit_text_sz(text, w, sz)
            let tw = measure_text(shown, sz)
            var tx = x + (w - tw) / 2
            if tx < x {
                tx = x
            }
            draw_text(shown, tx, y + (h - sz) / 2, sz, st.ink)
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
            draw_text(text, x + (w - tw) / 2, self._ty(y, h, st.text_size), st.text_size, st.muted_ink)
        } else if kind == _MENUITEM {
            let mw = hash(id)
            var col = st.ink
            if self.ui.hot == mw {                                 // accent highlight on hover (like a menu)
                fill_round(x, y, w, h, 6, st.accent, 255)
                col = st.accent_ink
            }
            draw_text(text, x + st.pad, self._ty(y, h, st.text_size), st.text_size, col)
        } else if kind == _MBLABEL || kind == _MBLABEL_ON {
            // A top-bar menu label: normal ink over a hover fill; the OPEN menu carries a stronger (pressed)
            // fill so the active menu reads as pinned down while its dropdown is showing.
            let mw = hash(id)
            if kind == _MBLABEL_ON {
                fill_round(x, y, w, h, st.radius, st.pressed, 255)
            } else if self.ui.hot == mw {
                fill_round(x, y, w, h, st.radius, st.hover, 255)
            }
            let tw = measure_text(text, st.text_size)
            draw_text(text, x + (w - tw) / 2, self._ty(y, h, st.text_size), st.text_size, st.ink)
        } else if kind == _MENUITEM_A {
            // A menu row with a right-aligned accelerator; text is "label\taccel". The accel stays muted even
            // on the accent hover (a hint, not an action), except it flips to accent_ink for contrast there.
            let mw = hash(id)
            var col  = st.ink
            var acol = st.muted_ink
            if self.ui.hot == mw {
                fill_round(x, y, w, h, 6, st.accent, 255)
                col  = st.accent_ink
                acol = st.accent_ink
            }
            let parts = text.split("\t")
            var lbl = text
            var acc = ""
            if parts.len() == 2 {
                lbl = parts[0]
                acc = parts[1]
            }
            let ty = self._ty(y, h, st.text_size)
            draw_text(lbl, x + st.pad, ty, st.text_size, col)
            let aw = measure_text(acc, st.text_size)
            draw_text(acc, x + w - st.pad - aw, ty, st.text_size, acol)
        } else if kind == _SUBMENU || kind == _SUBMENU_ON {
            // A submenu row (label + a trailing "▸" disclosure): highlit on hover OR while its nested menu is open.
            let mw = hash(id)
            var col = st.ink
            if kind == _SUBMENU_ON || self.ui.hot == mw {
                fill_round(x, y, w, h, 6, st.accent, 255)
                col = st.accent_ink
            }
            draw_text(text, x + st.pad, self._ty(y, h, st.text_size), st.text_size, col)
            let cr = st.text_size / 4
            self._tri_right(x + w - st.pad - cr, y + h / 2, cr, col)   // drawn "▸" (font-independent)
        } else if kind == _MENU_SEP {
            fill_round(x + st.pad, y + h / 2, w - st.pad * 2, 1, 0, st.border, 255)   // an inset grouping rule
        } else if kind == _CHECKBOX || kind == _CHECKBOX_ON {
            // a pill toggle (accent track + knob when ON) with a trailing label
            let cw = hash(id)
            let on = kind == _CHECKBOX_ON
            let tw = h + h / 2
            let th = h - 12
            let ty = y + (h - th) / 2
            var track = st.track
            if on {
                track = st.accent
            } else if self.ui.hot == cw {
                track = st.hover
            }
            fill_round(x, ty, tw, th, th / 2, track, 255)
            let kr = th / 2 - 2
            let cyk = ty + th / 2
            var kx = x + th / 2
            if on {
                kx = x + tw - th / 2
            }
            fill_round(kx - kr, cyk - kr, kr * 2, kr * 2, kr, st.accent_ink, 255)
            draw_text(text, x + tw + st.pad, self._ty(y, h, st.text_size), st.text_size, st.ink)
        } else if kind == _SLIDER {
            // a value track + draggable knob; `text` carries the fill fraction as permille (0..1000)
            let sw = hash(id)
            let permille = to_int(parse_float(text))
            var fillw = w * permille / 1000
            if fillw < 0 {
                fillw = 0
            }
            if fillw > w {
                fillw = w
            }
            let th = 6
            let cyk = y + h / 2
            fill_round(x, cyk - th / 2, w, th, th / 2, st.track, 255)
            if fillw > 0 {
                fill_round(x, cyk - th / 2, fillw, th, th / 2, st.accent, 255)
            }
            let kr = 9
            let kx = x + fillw
            var ring = st.border
            if self.ui.active == sw {
                ring = st.accent
            } else if self.ui.hot == sw {
                ring = ui.shade(st.accent, 20)
            }
            fill_round(kx - kr, cyk - kr, kr * 2, kr * 2, kr, st.accent_ink, 255)
            stroke_round(kx - kr, cyk - kr, kr * 2, kr * 2, kr, 1, ring, 200)
        } else if kind == _DROPDOWN {
            // a collapsed selector box: bordered surface, left label, right "▾" chevron; hover fill
            let dw = hash(id)
            var fill = st.panel
            if self.ui.active == dw {
                fill = st.pressed
            } else if self.ui.hot == dw {
                fill = st.hover
            }
            ui.card(x, y, w, h, fill, st, true)
            let ty = self._ty(y, h, st.text_size)
            let cr = st.text_size / 4                                  // chevron half-extent
            draw_text(self._fit_text(text, w - cr * 2 - st.pad * 3), x + st.pad, ty, st.text_size, st.ink)
            self._tri_down(x + w - st.pad - cr, y + h / 2, cr, st.muted_ink)   // drawn "▾" (font-independent)
        } else if kind == _TAB || kind == _TAB_ON {
            // a tab chip: label + a trailing "×" close zone. Active = panel fill + accent underline; inactive =
            // bar fill (hover-lit). "×" is U+00D7 (in the font's Latin-1 subset — renders, unlike "✕", OFI-170).
            let on = kind == _TAB_ON
            let bwid = hash(id)
            let xzone = st.text_size + st.pad
            var fill = st.bar
            var ink = st.muted_ink
            if on {
                fill = st.panel
                ink = st.ink
            } else if self.ui.hot == bwid {
                fill = st.hover
                ink = st.ink
            }
            fill_round(x, y, w, h, st.radius, fill, 255)
            let ty = self._ty(y, h, st.text_size)
            draw_text(self._fit_text(text, w - xzone - st.pad), x + st.pad, ty, st.text_size, ink)
            let xw = measure_text("×", st.text_size)
            draw_text("×", x + w - xzone / 2 - xw / 2, ty, st.text_size, st.muted_ink)
            if on {
                fill_round(x + st.pad, y + h - 2, w - st.pad * 2, 2, 0, st.accent, 255)   // active underline
            }
        }
    }


    // _ty returns the y to draw `size`-px text VERTICALLY CENTRED in a box [boxy, boxy+h]. draw_text lays
    // glyphs on the font's LINE BOX (ascender + descender) with that box's TOP at the given y, and text_size
    // is shorter than the line box AND top-aligned — so centring a text_size-tall box leaves a gap above the
    // caps and the text reads slightly LOW. Centring the TRUE line height fixes it (matches std/ui's field
    // centring). Every padded control (button / ghost / menu item / nav row / dock title / tab chip) routes
    // its vertical text placement through here, so they all centre identically and can't drift apart again.
    fn _ty(self, boxy: int, h: int, size: int) -> int {
        return boxy + (h - text_line_height(size)) / 2
    }


    // _tri_down / _tri_right paint a small solid triangle from stacked 1px bars, centred on (cx, cy) with
    // half-extent `r`. Font-INDEPENDENT — the embedded body font's subset omits the geometric-shape glyphs
    // (▾ ▸ render as tofu), so menu/dropdown chevrons are drawn, not typed. `r ≈ text_size/4` reads well.
    fn _tri_down(self, cx: int, cy: int, r: int, col: int) {
        var i = 0
        loop {
            if i > r {
                break
            }
            let ww = (r - i) * 2 + 1                       // widest at the top row, narrowing to a point
            fill_round(cx - (r - i), cy - r + i, ww, 1, 0, col, 255)
            i = i + 1
        }
    }


    fn _tri_right(self, cx: int, cy: int, r: int, col: int) {
        var i = 0
        loop {
            if i > r {
                break
            }
            let hh = (r - i) * 2 + 1                       // tallest at the left column, narrowing to a point
            fill_round(cx - r + i, cy - (r - i), 1, hh, 0, col, 255)
            i = i + 1
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
        draw_text(text, x + (w - tw) / 2, self._ty(y + oy, h, st.text_size), st.text_size, ink)
    }


    // _paint_nav renders a nav_item: a full-width row with LEFT-aligned text (a left pad), the accent fill
    // when active, else the theme hover/pressed states — the sidebar-list counterpart to centred _paint_button.
    fn _paint_nav(mut self, text: string, id: string, x: int, y: int, w: int, h: int, active: bool) {
        let st = self.ui.style
        let wid = hash(id)
        var ink = st.ink
        var oy = 0
        // A nav row is FLAT at rest — no card, no border, no shadow, just text (the modern sidebar look:
        // VS Code / Linear / Notion). A fill appears only on hover/press, and the ACTIVE row carries the
        // accent. So a list of idle rows reads as clean text, not a stack of outlined pills.
        if active {
            var fill = st.accent
            if self.ui.active == wid {
                fill = ui.shade(st.accent, -16)
                oy = 1
            } else if self.ui.hot == wid {
                fill = ui.shade(st.accent, 14)
            }
            fill_round(x, y + oy, w, h, st.radius, fill, 255)
            ink = st.accent_ink
        } else if self.ui.active == wid {
            oy = 1
            fill_round(x, y + oy, w, h, st.radius, st.pressed, 255)
        } else if self.ui.hot == wid {
            fill_round(x, y, w, h, st.radius, st.hover, 255)
        }
        draw_text(text, x + st.pad, self._ty(y + oy, h, st.text_size), st.text_size, ink)
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
        ds: map.Map<string, Rect>{ buckets: [], count: 0 },
        dpin: [],
        pdrag: "",
        pox: 0,
        poy: 0,
        _submit: false,
        _rdown: false,
        _rwas: false,
        _last_wid: 0,
        mono: -1,
        italic: -1,
        zoom: 100,
        _mdseq: 0,
        _modal: false,
        _in_modal: false,
        _modal_was: false,
        _anim: false,
        _steps: 1,
        _realtime: false,
        vrows: [],
        vcount: 0,
        vstart: 0,
        vend: 0,
        _vk: 0,
        _frame: 0,
        _toasts: [],
        _tnext: 0,
        _action: ""
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
    // A leaf is a TAB GROUP: dk_tabs[i] is its panel ids (≥1), dk_active[i] the index of the visible one.
    // dk_panel[i] mirrors the ACTIVE tab (dk_tabs[i][dk_active[i]]) — a cached convenience the renderer,
    // leaves(), and apps read as "the panel this leaf is showing", kept in sync by _sync_panel after any
    // tab/active change. A single-panel leaf is just a one-tab group, so non-tabbed docking is unchanged.
    dk_tabs: [[string]]
    dk_active: [int]
    dk_panel: [string]   // leaf: the ACTIVE tab's panel id (mirror of dk_tabs[i][dk_active[i]]); split: ""
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
            self.dk_tabs.append([])
            self.dk_active.append(0)
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
        self.dk_tabs[idx]   = []
        self.dk_active[idx] = 0
        self.dk_panel[idx]  = ""
        return idx
    }


    // _release marks a slot free and drops its panel/tab data, so it can be recycled by _alloc.
    fn _release(mut self, i: int) {
        self.dk_kind[i]   = 0
        self.dk_panel[i]  = ""
        self.dk_tabs[i]   = []
        self.dk_active[i] = 0
        self.dk_a[i]      = -1
        self.dk_b[i]      = -1
        self.dk_parent[i] = -1
    }


    // _sync_panel refreshes a leaf's dk_panel mirror from its active tab — call after any change to a
    // leaf's tab list or active index. A leaf always has ≥1 tab while live, so the index is in range.
    fn _sync_panel(mut self, i: int) {
        var a = self.dk_active[i]
        if a < 0 { a = 0 }
        if a >= self.dk_tabs[i].len() { a = self.dk_tabs[i].len() - 1 }
        self.dk_active[i] = a
        self.dk_panel[i] = self.dk_tabs[i][a]
    }


    // add_root creates the first panel as the tree root and returns its leaf index. Use only on an
    // empty tree (root == -1); the first panel docked into an app's workspace.
    fn add_root(mut self, panel: string) -> int {
        let i = self._alloc(1, -1)
        self.dk_tabs[i] = [panel]
        self.dk_active[i] = 0
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
        self.dk_tabs[nl] = [panel]
        self.dk_active[nl] = 0
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


    // split_before is split()'s mirror: it docks `panel` on the LEADING side of `leaf` — the new panel is
    // child A (left / top) and the existing leaf child B (right / bottom). `ratio` is still child A's (the
    // new panel's) fraction. Use it to re-dock a closed sidebar back on the left, vs split() for the right.
    fn split_before(mut self, leaf: int, panel: string, vertical: bool, ratio: float) -> int {
        let p = self.dk_parent[leaf]
        let s = self._alloc(2, p)
        let nl = self._alloc(1, s)
        self.dk_tabs[nl] = [panel]
        self.dk_active[nl] = 0
        self.dk_panel[nl] = panel
        self.dk_a[s]     = nl
        self.dk_b[s]     = leaf
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


    // leaf_of returns the node index of the leaf holding `panel` (in ANY of its tabs, not only the active
    // one), or -1 if no panel by that id is docked. The id→index lookup an app uses to re-dock beside a
    // known panel, or to test whether one is open.
    fn leaf_of(self, panel: string) -> int {
        var i = 0
        loop {
            if i == self.dk_kind.len() { break }
            if self.dk_kind[i] == 1 {
                var j = 0
                loop {
                    if j == self.dk_tabs[i].len() { break }
                    if self.dk_tabs[i][j] == panel { return i }
                    j = j + 1
                }
            }
            i = i + 1
        }
        return -1
    }


    // tabs_of returns a COPY of `leaf`'s tab panel ids (empty for a non-leaf) — the app uses it to forget
    // every tab's state when a whole leaf closes, or to render its own tab affordances.
    fn tabs_of(self, leaf: int) -> [string] {
        if self.dk_kind[leaf] != 1 { return [] }
        return self.dk_tabs[leaf].clone()
    }


    // tab_count returns how many panels are grouped as tabs in `leaf` (0 for a non-leaf).
    fn tab_count(self, leaf: int) -> int {
        if self.dk_kind[leaf] != 1 { return 0 }
        return self.dk_tabs[leaf].len()
    }


    // active_tab returns `leaf`'s active tab index (the visible panel), or -1 for a non-leaf.
    fn active_tab(self, leaf: int) -> int {
        if self.dk_kind[leaf] != 1 { return -1 }
        return self.dk_active[leaf]
    }


    // set_active makes tab `idx` the visible one in `leaf` (clamped), refreshing the dk_panel mirror.
    fn set_active(mut self, leaf: int, idx: int) {
        if self.dk_kind[leaf] != 1 { return }
        self.dk_active[leaf] = idx
        self._sync_panel(leaf)
    }


    // add_tab groups `panel` into `leaf` as a new tab and makes it active — the data op behind a centre-drop
    // (tabify). The panel must already be detached from its previous spot (redock/tabify call _detach first).
    fn add_tab(mut self, leaf: int, panel: string) {
        if self.dk_kind[leaf] != 1 { return }
        self.dk_tabs[leaf].append(panel)
        self.dk_active[leaf] = self.dk_tabs[leaf].len() - 1
        self._sync_panel(leaf)
    }


    // _detach removes `panel` from wherever it is docked WITHOUT destroying its sibling tabs: if its leaf has
    // more than one tab, just that tab is dropped (the leaf survives, active index clamped); if it is the leaf's
    // only tab, the leaf is closed and its parent split collapses (like close()). Returns false on unknown panel.
    // The shared first step of redock/tabify/dock_root_edge — so dragging ONE tab out of a group leaves the rest.
    fn _detach(mut self, panel: string) -> bool {
        let l = self.leaf_of(panel)
        if l == -1 { return false }
        if self.dk_tabs[l].len() <= 1 {
            let _ = self.close(l)
            return true
        }
        var fresh: [string] = []
        var j = 0
        loop {
            if j == self.dk_tabs[l].len() { break }
            if self.dk_tabs[l][j] != panel { fresh.append(self.dk_tabs[l][j]) }
            j = j + 1
        }
        self.dk_tabs[l] = fresh                       // _sync_panel re-clamps the active index to the new length
        self._sync_panel(l)
        return true
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


    // close_tab closes the ACTIVE tab of `leaf`: if the leaf has other tabs the group survives (the next tab
    // becomes active) and only that panel id is returned; if it was the leaf's LAST tab the leaf is closed and
    // its parent split collapses, exactly like close(). Returns the removed panel id so the caller can
    // f.forget() its state. This is what a panel's close ✕ triggers — per-tab, not per-leaf.
    fn close_tab(mut self, leaf: int) -> string {
        if self.dk_kind[leaf] != 1 { return "" }
        if self.dk_tabs[leaf].len() <= 1 {
            return self.close(leaf)
        }
        let gone = self.dk_panel[leaf]
        var fresh: [string] = []
        var j = 0
        loop {
            if j == self.dk_tabs[leaf].len() { break }
            if self.dk_tabs[leaf][j] != gone { fresh.append(self.dk_tabs[leaf][j]) }
            j = j + 1
        }
        self.dk_tabs[leaf] = fresh                    // _sync_panel re-clamps the active index to the new length
        self._sync_panel(leaf)
        return gone
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


    // redock moves an already-docked `panel` to a new position relative to `target` — the tree op behind
    // drag-to-redock. `side`: 0 = left, 1 = right, 2 = top, 3 = bottom (a new split beside `target`), or 4 =
    // CENTRE (group `panel` into `target`'s leaf as a TAB). It DETACHES `panel` from its current spot first
    // (dropping just that tab if it shared a group, else collapsing its leaf) and re-resolves `target` by id
    // AFTER, so a slot reshuffle can't stale an index. The panel keeps its id ⇒ its Flare state survives the
    // move. No-ops (false) on a self-drop or an unknown panel/target. Left/top make the panel child A.
    fn redock(mut self, panel: string, target: string, side: int) -> bool {
        if panel == target { return false }
        if self.leaf_of(panel) == -1 { return false }
        if self.leaf_of(target) == -1 { return false }
        let _ = self._detach(panel)                   // pull panel out; a grouped tab leaves its siblings intact
        let tl = self.leaf_of(target)                 // target survives detach; re-resolve its (maybe-new) index
        if tl == -1 {
            self.add_root(panel)                      // defensive: target vanished → don't lose the panel
            return false
        }
        if side == 4 {
            self.add_tab(tl, panel)                   // centre drop → group as a tab of target's leaf
            return true
        }
        let vert = side == 0 || side == 1             // left/right → side-by-side; top/bottom → stacked
        if side == 0 || side == 2 {
            self.split_before(tl, panel, vert, 0.4)   // panel leads (left / top), the smaller share
        } else {
            self.split(tl, panel, vert, 0.6)          // panel trails (right / bottom); target keeps 0.6
        }
        return true
    }


    // dock_root_edge docks `panel` against an OUTER edge of the whole workspace — it wraps the entire root
    // (leaf OR split) in a fresh split with `panel` on the given `side` (0=left,1=right,2=top,3=bottom). Like
    // redock it detaches the panel first, then re-inserts it; if the panel WAS the whole tree it is simply
    // re-seeded as the lone root. Returns false on an unknown panel. The new outer strip takes ~30%.
    fn dock_root_edge(mut self, panel: string, side: int) -> bool {
        if self.leaf_of(panel) == -1 { return false }
        let _ = self._detach(panel)
        if self.root == -1 {
            self.add_root(panel)                      // panel was the only leaf — nothing to wrap
            return true
        }
        let old = self.root
        let s = self._alloc(2, -1)
        let nl = self._alloc(1, s)
        self.dk_tabs[nl] = [panel]
        self.dk_active[nl] = 0
        self.dk_panel[nl] = panel
        self.dk_vert[s] = side == 0 || side == 1
        if side == 0 || side == 2 {                   // left / top → new panel is child A (leading)
            self.dk_a[s] = nl
            self.dk_b[s] = old
            self.dk_ratio[s] = 0.3
        } else {
            self.dk_a[s] = old
            self.dk_b[s] = nl
            self.dk_ratio[s] = 0.7
        }
        self.dk_parent[old] = s
        self.root = s
        return true
    }


    // to_json serialises the tree to a std/json value an app can persist (the workspace survives relaunch —
    // OFI-112). It stores every slot as-is (free slots included) so node INDICES round-trip exactly, with no
    // re-indexing: per node kind/parent/a/b, the split's vert (0|1) + ratio (as int·1000, since std/json
    // numbers are ints), and the leaf's tab list + active index. dk_panel is DERIVED (re-synced on load) and
    // the solved rects are transient, so neither is stored. dock_from_json is the inverse.
    fn to_json(self) -> json.Json {
        var nodes: [json.Json] = []
        var i = 0
        loop {
            if i == self.dk_kind.len() { break }
            var tabs: [json.Json] = []
            var j = 0
            loop {
                if j == self.dk_tabs[i].len() { break }
                tabs.append(json.str(self.dk_tabs[i][j]))
                j = j + 1
            }
            var vert = 0
            if self.dk_vert[i] { vert = 1 }
            nodes.append(json.obj([
                json.member("k", json.num(self.dk_kind[i])),
                json.member("p", json.num(self.dk_parent[i])),
                json.member("a", json.num(self.dk_a[i])),
                json.member("b", json.num(self.dk_b[i])),
                json.member("v", json.num(vert)),
                json.member("r", json.num(to_int(self.dk_ratio[i] * 1000.0))),
                json.member("act", json.num(self.dk_active[i])),
                json.member("tabs", json.arr(tabs))
            ]))
            i = i + 1
        }
        return json.obj([
            json.member("root", json.num(self.root)),
            json.member("nodes", json.arr(nodes))
        ])
    }
}


// dock_new builds an empty DockTree (no panels). Add the first panel with add_root.
fn dock_new() -> DockTree {
    return DockTree {
        dk_kind: [], dk_parent: [], dk_a: [], dk_b: [], dk_vert: [], dk_ratio: [],
        dk_tabs: [], dk_active: [], dk_panel: [],
        dk_x: [], dk_y: [], dk_w: [], dk_h: [],
        root: -1
    }
}


// dock_from_json rebuilds a DockTree saved by to_json (OFI-112): it restores the slotmap arrays slot-for-slot
// (indices preserved), decodes vert from 0|1 and ratio from int·1000, and re-syncs each leaf's dk_panel mirror
// from its active tab. Pair with leaf_of() to validate the result before adopting it (e.g. that the app's
// pinned panel is present) and fall back to a freshly built default if the stored layout is absent/corrupt.
fn dock_from_json(j: json.Json) -> DockTree {
    var t = dock_new()
    let nodes = json.get(j, "nodes")
    let n = json.length(nodes)
    var i = 0
    loop {
        if i == n { break }
        let nd = json.at(nodes, i)
        t.dk_kind.append(json.as_int(json.get(nd, "k")))
        t.dk_parent.append(json.as_int(json.get(nd, "p")))
        t.dk_a.append(json.as_int(json.get(nd, "a")))
        t.dk_b.append(json.as_int(json.get(nd, "b")))
        t.dk_vert.append(json.as_int(json.get(nd, "v")) == 1)
        t.dk_ratio.append(to_float(json.as_int(json.get(nd, "r"))) / 1000.0)
        t.dk_active.append(json.as_int(json.get(nd, "act")))
        var tabs: [string] = []
        let tj = json.get(nd, "tabs")
        let m = json.length(tj)
        var k = 0
        loop {
            if k == m { break }
            tabs.append(json.as_str(json.at(tj, k)))
            k = k + 1
        }
        t.dk_tabs.append(tabs)
        t.dk_panel.append("")
        t.dk_x.append(0)
        t.dk_y.append(0)
        t.dk_w.append(0)
        t.dk_h.append(0)
        i = i + 1
    }
    t.root = json.as_int(json.get(j, "root"))
    i = 0
    loop {
        if i == t.dk_kind.len() { break }
        if t.dk_kind[i] == 1 && t.dk_tabs[i].len() > 0 {
            t._sync_panel(i)            // restore dk_panel from the active tab
        }
        i = i + 1
    }
    return t
}


// dock_zone classifies where the cursor (mx,my) falls inside a panel rect for drag-to-redock — pure geometry
// so the drop logic is headless-testable. Returns -1 outside the rect, 4 for the centre box (tabify, inert in
// v1), else the nearest EDGE: 0 left, 1 right, 2 top, 3 bottom. The middle third on BOTH axes is the centre;
// otherwise the closest edge wins, distances NORMALISED by the rect's own width/height (via cross-multiply, so
// a wide panel doesn't bias toward the horizontal edges). The 0..3 result matches redock()/dock_root_edge()'s
// `side`, so a hovered zone maps straight to a tree mutation.
fn dock_zone(x: int, y: int, w: int, h: int, mx: int, my: int) -> int {
    if mx < x { return -1 }
    if mx >= x + w { return -1 }
    if my < y { return -1 }
    if my >= y + h { return -1 }
    let lx = mx - x                  // distance from each edge (px)
    let rx = x + w - mx
    let ty = my - y
    let by = y + h - my
    if lx * 3 > w && rx * 3 > w && ty * 3 > h && by * 3 > h {
        return 4                     // middle third of both axes → centre (tabify)
    }
    let dl = lx * h                  // normalise: dist/dimension, scaled by w*h so all four compare on one ruler
    let dr = rx * h
    let dt = ty * w
    let db = by * w
    var best = 0
    var bv = dl
    if dr < bv { best = 1  bv = dr }
    if dt < bv { best = 2  bv = dt }
    if db < bv { best = 3  bv = db }
    return best
}
