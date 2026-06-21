// std/ui — an immediate-mode widget toolkit over std/draw's primitives (MANIFESTO
// §5g). The whole UI is a pure function of state: there is NO retained widget tree.
// A `Ui` value carries the small cross-frame state immediate mode needs — the layout
// cursor, this frame's input snapshot, which widget is `hot` (hovered) or `active`
// (being pressed), and the `Style` (theme). You hold it as a `var` and thread it
// through your loop: `begin` once per frame, then widgets, then `end`. Each widget
// lays itself out AND returns its interaction as a value — no callbacks, no widget tree.
//
//   var u = ui.new()                  // or ui.themed(ui.light())
//   loop {
//       if draw.closing() { break }
//       draw.begin(u.style.bg)
//       u.begin()
//       if u.button("increment") { count = count + 1 }
//       u.label("count = {count}")
//       u.end()
//       draw.finish()
//   }

import "std/map" as map
import "std/string" as str

let NONE = -1            // "no widget" id (hash() is always >= 0)

let KEY_BACKSPACE = 259  // raylib key codes used by text input
let KEY_ENTER     = 257
let KEY_RIGHT     = 262
let KEY_LEFT      = 263
let KEY_DOWN      = 264  // multi-line caret navigation (text area)
let KEY_UP        = 265
let KEY_DELETE    = 261
let KEY_HOME      = 268
let KEY_END       = 269
let KEY_A         = 65   // select-all / copy / cut / paste letters (raylib uses ASCII for letters)
let KEY_C         = 67
let KEY_V         = 86
let KEY_X         = 88
let KEY_LSHIFT    = 340  // selection-extend modifier (either side)
let KEY_RSHIFT    = 344
let KEY_LCTRL     = 341  // the "command" modifier: ctrl (Win/Linux) OR super/⌘ (macOS), either side
let KEY_RCTRL     = 345
let KEY_LSUPER    = 343
let KEY_RSUPER    = 347

// Mouse-cursor shapes (Ember-abstract, raylib-independent — graphics.c maps them to the OS pointer).
// Pass to set_cursor(); the default is reasserted every frame, so a widget only sets its shape while hovered.
let CURSOR_DEFAULT   = 0
let CURSOR_RESIZE_EW = 1   // ↔ horizontal resize — a vertical splitter bar
let CURSOR_RESIZE_NS = 2   // ↕ vertical resize — a horizontal splitter bar
let CURSOR_HAND      = 3   // a clickable affordance
let CURSOR_IBEAM     = 4   // editable / selectable text






// VLine is one VISUAL line of a wrapped text area: the code-point index in the buffer where it begins,
// plus its text (the buffer slice, minus the consumed wrap-space / newline). A multi-line field maps the
// flat caret to/from these to edit, place, and hit-test in 2D over a single flat code-point buffer.
struct VLine {
    start: int
    text: string
}


// _wrap_para word-wraps one paragraph `para` (no newlines), beginning at buffer code-point `base`, to
// `width` px — returning its visual lines with correct buffer start indices. A word wider than the width
// overflows its own line rather than splitting mid-word (same greedy rule as wrap()).
fn _wrap_para(base: int, para: string, width: int, size: int) -> [VLine] {
    var out: [VLine] = []
    let words = para.split(" ")
    var cur = ""
    var cur_start = base
    var off = base
    var i = 0
    loop {
        if i == words.len() {
            break
        }
        var trial = words[i]
        if cur.len() > 0 {
            trial = cur + " " + words[i]
        }
        if measure_text(trial, size) > width && cur.len() > 0 {
            out.append(VLine { start: cur_start, text: cur })
            cur = words[i]
            cur_start = off
        } else {
            cur = trial
        }
        off = off + str.cp_count(words[i]) + 1   // + 1 for the space separator that follows this word
        i = i + 1
    }
    out.append(VLine { start: cur_start, text: cur })
    return out
}


// _wrap_lines splits `buf` into VISUAL lines: hard newlines are honoured (each begins a fresh line, and a
// blank line stays blank), and each paragraph is word-wrapped to `width`. The start indices let a text area
// place + hit-test a flat code-point caret in 2D.
fn _wrap_lines(buf: string, width: int, size: int) -> [VLine] {
    var out: [VLine] = []
    let paras = buf.split("\n")
    var base = 0
    var p = 0
    loop {
        if p == paras.len() {
            break
        }
        if paras[p].len() == 0 {
            out.append(VLine { start: base, text: "" })
        } else {
            let ls = _wrap_para(base, paras[p], width, size)
            var k = 0
            loop {
                if k == ls.len() {
                    break
                }
                out.append(VLine { start: ls[k].start, text: ls[k].text })   // fresh (no struct move out of array)
                k = k + 1
            }
        }
        base = base + str.cp_count(paras[p]) + 1   // + 1 for the '\n' that separated this paragraph
        p = p + 1
    }
    return out
}


// code_caret_at maps a pixel (mx,my) to a code-point index in `src`, treated as LITERAL monospace
// lines — one source line per visual row, no wrapping (the read-only code panel, unlike a wrapped
// text area). The mono font must be the active font when this runs, so the per-line x→column
// measurement matches what _paint_code draws. tx,ty0 = the text origin (top-left of the first line);
// cs = the character size; lh = the line height. The result is clamped into the source.
fn code_caret_at(src: string, tx: int, ty0: int, cs: int, lh: int, mx: int, my: int) -> int {
    let lines = src.split("\n")
    var row = (my - ty0) / lh
    if row < 0 {
        row = 0
    }
    if row >= lines.len() {
        row = lines.len() - 1
    }
    var base = 0
    var i = 0
    loop {
        if i == row {
            break
        }
        base = base + str.cp_count(lines[i]) + 1   // + 1 for the '\n' that ended this line
        i = i + 1
    }
    return base + cp_caret_from_x(lines[row], mx - tx, cs)
}




// cp_caret_from_x returns the code-point index whose boundary is nearest pixel offset relx.
fn cp_caret_from_x(s: string, relx: int, size: int) -> int {
    let n = str.cp_count(s)
    var best = 0
    var best_d = relx
    if best_d < 0 {
        best_d = -best_d
    }
    var i = 1
    loop {
        if i > n {
            return best
        }
        var d = relx - measure_text(str.cp_prefix(s, i), size)
        if d < 0 {
            d = -d
        }
        if d < best_d {
            best_d = d
            best = i
        }
        i = i + 1
    }
    return best
}

let POPUP_LAYER = 1000000  // menus/tooltips draw far above every window's layer
let MENU_W      = 160      // dropdown menu width (fixed for now)


// rgb packs 8-bit channels into the 0xRRGGBB int the backend expects. Writing themes as
// rgb(76, 141, 246) is clearer and less error-prone than a raw decimal literal.
fn rgb(r: int, g: int, b: int) -> int {
    return r * 65536 + g * 256 + b
}


// clamp8 keeps a channel in 0..255 (used by shade after adding/subtracting brightness).
fn clamp8(v: int) -> int {
    if v < 0 {
        return 0
    }
    if v > 255 {
        return 255
    }
    return v
}


// shade lightens (d > 0) or darkens (d < 0) a packed color by `d` per channel — the basis
// of the subtle gradients and hover states that give widgets depth without new theme fields.
fn shade(c: int, d: int) -> int {
    let r = clamp8((c / 65536) % 256 + d)
    let g = clamp8((c / 256) % 256 + d)
    let b = clamp8(c % 256 + d)
    return r * 65536 + g * 256 + b
}


// Style is a theme: a palette (packed 0xRRGGBB colors) plus metrics. Swap it whole
// (`u.style = ui.light()`) or tweak a field — every widget reads from it, so theming
// is just data.
struct Style {
    bg: int          // window background
    panel: int       // idle widget fill
    hover: int       // hovered widget fill
    pressed: int     // pressed widget fill
    ink: int         // primary text
    muted_ink: int   // secondary text (labels, hints)
    accent: int      // slider fill / toggle-on / focus ring / selection
    accent_ink: int  // text or knob drawn ON the accent colour
    border: int      // hairline widget border
    track: int       // slider / toggle / scrollbar track
    radius: int      // corner radius (px)
    pad: int         // padding inside and between widgets
    text_size: int
    row_h: int       // widget row height
    shadow: int      // drop-shadow alpha (0..255; 0 disables elevation)
}


// dark is the default theme — a calm slate palette with a blue accent (editor-style).
fn dark() -> Style {
    return Style {
        bg: rgb(27, 29, 35), panel: rgb(42, 45, 54), hover: rgb(53, 57, 69),
        pressed: rgb(35, 38, 48), ink: rgb(236, 238, 242), muted_ink: rgb(150, 156, 170),
        accent: rgb(76, 141, 246), accent_ink: rgb(255, 255, 255), border: rgb(58, 62, 74),
        track: rgb(58, 62, 74), radius: 8, pad: 8, text_size: 20, row_h: 34, shadow: 70
    }
}


// light is a high-key theme — near-white surfaces, soft shadows, the same blue accent.
fn light() -> Style {
    return Style {
        bg: rgb(244, 245, 248), panel: rgb(255, 255, 255), hover: rgb(238, 240, 245),
        pressed: rgb(228, 231, 238), ink: rgb(28, 31, 38), muted_ink: rgb(110, 116, 128),
        accent: rgb(42, 125, 246), accent_ink: rgb(255, 255, 255), border: rgb(214, 218, 226),
        track: rgb(220, 224, 232), radius: 8, pad: 8, text_size: 20, row_h: 34, shadow: 35
    }
}


// card draws the standard widget surface: an optional soft drop shadow (elevation), a flat
// rounded fill, and a hairline border. Every raised control is a card plus its own content, so the
// look is defined in one place and themes flow through `st`. The fill is FLAT, not a gradient: a
// single-colour rounded rect plus an inset vertical gradient always leaves a seam where the
// gradient's straight edge meets the rounded corners, so depth comes from the shadow + border +
// hover/press state instead (the modern flat-design approach — egui, macOS).
fn card(x: int, y: int, w: int, h: int, fill: int, st: Style, raised: bool) {
    if raised && st.shadow > 0 {
        shadow(x, y + 2, w, h, st.radius, st.shadow)
    }
    fill_round(x, y, w, h, st.radius, fill, 255)
    stroke_round(x, y, w, h, st.radius, 1, st.border, 110)
}


// Window is one entry in the persistent window registry: its top-left position (a title-bar drag
// updates it), its auto-fitted size, and its z-order (higher is nearer the front). One per window,
// keyed by window id in the Ui's `wins` map — so all of a window's state travels together and can
// never desync the way six parallel arrays could.
struct Window {
    x: int
    y: int
    w: int
    h: int
    z: int
}


struct Ui {
    cx: int         // layout cursor x (where the next widget goes)
    cy: int         // layout cursor y
    line_x: int     // left margin of the current column (a new line returns here)
    row_max: int    // bottom-most y reached so far (the next line drops below it)
    last_x: int     // the last widget's x, y, width — so same_line can sit beside it
    last_y: int
    last_w: int
    mx: int         // mouse x this frame
    my: int         // mouse y this frame
    down: bool      // left button held this frame
    was: bool       // left button held last frame
    hot: int        // id of the widget under the mouse (NONE if none)
    active: int     // id of the widget being pressed (NONE if none)
    id_pre: string  // id-scope prefix mixed into every widget id (the IMGUI id-stack / React
                    // `key`): "" by default so ids stay hash(label) exactly, set per list item or
                    // component (e.g. by std/flare) so same-labelled widgets don't collide
    focus: int      // id of the focused text field (NONE if none)
    buf: string     // edit buffer of the focused text field
    caret: int      // caret position in the focused field, in code points (the MOVING end of a selection)
    sel_anchor: int // the FIXED end of the selection; the selected range is [min(anchor,caret),
                    // max(anchor,caret)). anchor == caret means no selection. Reset to caret on focus.
    text_off: int   // horizontal scroll of the focused field, in pixels — shifts the text left so the
                    // caret stays inside the field when the value is wider than it (reset on focus)
    frame: int      // frame counter (drives the caret blink), bumped each begin()
    // --- window system (Phase B): a persistent registry of Window records keyed by window
    // id (hash of title). Window state must survive across frames (position, z-order), so
    // unlike the per-frame layout fields this is NOT reset in begin(). One struct per window
    // means the old six-parallel-array desync invariant is now structural (unrepresentable).
    wins: map.Map<int, Window>
    z_top: int          // next z to hand out; focusing a window takes it and bumps it
    hover_win: int      // topmost window under the mouse THIS frame (from last frame's rects)
    cur_win: int        // window currently being built (NONE while laying out the background)
    drag_id: int        // window being dragged by its title bar (NONE if none)
    drag_dx: int        // mouse-to-origin offset captured when a drag began
    drag_dy: int
    save_cx: int        // background layout cursor, saved across a window's widgets
    save_cy: int
    save_line_x: int
    save_row_max: int
    content_x: int      // rightmost / bottom-most content edge reached inside it
    content_y: int      //   (drives next frame's auto-size, the last-frame trick again)
    cur_title_w: int    // min width needed to fit the current window's title
    // --- popups (Phase B3): one dropdown menu open at a time, modal while open ---
    open_popup: int     // id of the open menu (NONE if none)
    pop_x: int          // open menu's left edge
    pop_y: int          // next item's y inside the open menu (and last frame's extent)
    pop_y0: int         // first item's y (top of the item list)
    pop_hx: int         // open menu's header rect — clicks here don't count as "outside"
    pop_hy: int
    pop_hw: int
    // --- scroll region (one active at a time): offset persists across frames like windows ---
    sc_off: int         // current vertical scroll offset (persists; clamped to sc_max)
    sc_max: int         // last frame's maximum offset (content_h - viewport_h), for clamp + thumb
    sc_x: int           // active viewport rect (set by scroll_begin, used by scroll_end)
    sc_y: int
    sc_w: int
    sc_h: int
    sc_line_x: int      // the enclosing left margin, saved across the region
    sc_drag: bool       // dragging the scrollbar thumb
    sc_drag_dy: int     // mouse-to-thumb-top offset captured when the drag began
    // --- splitter resize latch (one at a time; independent of the window/scrollbar latches so the three
    // can never desync). Absolute-anchor model: the new size = sp_base + the mouse's total travel since the
    // press, so it is independent of the handle's own moving position as the pane resizes under the cursor ---
    sp_drag: int        // id of the splitter being dragged (NONE if none)
    sp_grab: int        // mouse axis (mx or my) captured at the press
    sp_base: int        // the pane size captured at the press
    style: Style    // the active theme


    // begin captures this frame's input and resets per-frame layout + hot state.
    // `active` persists across frames (a press spans frames) until release. The
    // postconditions pin the frame-start invariant — a void mutator stating a
    // postcondition on its own state, which OFI-026 (a latent uninitialised-field bug)
    // had blocked: nothing is hovered yet and the cursor sits at the top-left margin.
    fn begin(mut self)
        ensures self.hot == NONE
        ensures self.cx == self.style.pad
        ensures self.cur_win == NONE
    {
        self.was  = self.down
        self.down = mouse_down()
        self.mx   = mouse_x()
        self.my   = mouse_y()
        self.frame = self.frame + 1
        self.hot     = NONE
        self.cx      = self.style.pad
        self.cy      = self.style.pad
        self.line_x  = self.style.pad
        self.row_max = self.style.pad
        self.last_x  = self.style.pad
        self.last_y  = self.style.pad
        self.last_w  = 0
        self.cur_win = NONE          // the background is the implicit layer-0 surface
        set_layer(0)

        // Resolve the topmost window under the mouse from LAST frame's rects (this
        // frame's geometry isn't known until window_begin runs). Only that window's
        // widgets will be allowed to interact — clicks can't fall through to one behind.
        self.hover_win = NONE
        var best = -1
        let ids = self.wins.keys()
        var i = 0
        loop {
            if i >= ids.len() {
                break
            }
            let id = ids[i]
            match self.wins.get(id) {
                case Some(w) {
                    let over = self.mx >= w.x && self.mx < w.x + w.w &&
                               self.my >= w.y && self.my < w.y + w.h
                    if over && w.z > best {
                        best = w.z
                        self.hover_win = id
                    }
                }
                case None {}
            }
            i = i + 1
        }
    }


    // advance records a just-placed widget's rect and parks the cursor on a fresh line
    // below the tallest widget seen so far. `same_line` (called next) overrides this to
    // sit beside the last widget instead. Every widget ends by calling this, so layout
    // lives in one place — rows, groups, and indent build on it without touching widgets.
    fn advance(mut self, x: int, y: int, w: int, h: int) {
        self.last_x = x
        self.last_y = y
        self.last_w = w
        let bottom = y + h
        if bottom > self.row_max {
            self.row_max = bottom
        }
        self.cx = self.line_x
        self.cy = self.row_max + self.style.pad
        // Inside a window, grow its recorded content extent so it can auto-size to fit.
        if self.cur_win != NONE {
            let right = x + w
            if right > self.content_x {
                self.content_x = right
            }
            if bottom > self.content_y {
                self.content_y = bottom
            }
        }
    }


    // same_line puts the next widget to the RIGHT of the one just placed, on the same
    // row, instead of below it. Call it between two widgets: `u.button("a"); u.same_line();
    // u.button("b")`. The following normal widget drops below the tallest item in the row.
    fn same_line(mut self) {
        self.cx = self.last_x + self.last_w + self.style.pad
        self.cy = self.last_y
    }


    // indent shifts the left margin right by one row-height, so the widgets that follow
    // sit in a nested group. Pair with `unindent`. Calls nest, so indent twice to nest
    // twice. Only takes effect at the start of a fresh line (the next `advance`).
    fn indent(mut self) {
        self.line_x = self.line_x + self.style.row_h
        self.cx = self.line_x
    }


    // unindent undoes one `indent`, returning the margin to the enclosing group.
    fn unindent(mut self) {
        self.line_x = self.line_x - self.style.row_h
        if self.line_x < self.style.pad {
            self.line_x = self.style.pad
        }
        self.cx = self.line_x
    }


    // spacing inserts `px` of vertical gap before the next widget.
    fn spacing(mut self, px: int) {
        self.cy = self.cy + px
    }


    // press runs the standard hot/active behavior over a widget's rect. A click is
    // "mouse pressed on the widget, then released while still over it".
    fn press(mut self, id: int, x: int, y: int, w: int, h: int) -> bool {
        // While a menu is open it is modal: every ordinary widget is inert (menu items
        // hit-test directly, not through here, so they still work).
        if self.open_popup != NONE {
            return false
        }
        // A widget interacts only if it belongs to the window under the mouse — for
        // background widgets that means no window is over the mouse (both are NONE).
        if self.cur_win != self.hover_win {
            return false
        }
        let over = self.mx >= x && self.mx < x + w && self.my >= y && self.my < y + h
        if over {
            self.hot = id
        }
        var clicked = false
        if self.active == id {
            if !self.down {                  // released
                if over {
                    clicked = true           // ...over the widget => a click
                }
                self.active = NONE
            }
        } else if over && self.down && !self.was {   // just pressed on this widget
            self.active = id
        }
        return clicked
    }




    // pressed_down reports the press DOWN-edge over a widget: the mouse went from up to down THIS
    // frame while over the rect (respecting the same occlusion guards as press). Where press() fires
    // on the click (down-then-release), this fires the instant the button goes down — which is what a
    // drag-to-select needs, so the anchor is dropped before the cursor moves. Read-only and stateless.
    fn pressed_down(self, id: int, x: int, y: int, w: int, h: int) -> bool {
        if self.open_popup != NONE {
            return false
        }
        if self.cur_win != self.hover_win {
            return false
        }
        let over = self.mx >= x && self.mx < x + w && self.my >= y && self.my < y + h
        return over && self.down && !self.was
    }




    // _split_drag runs one frame of INPUT for a draggable resize handle (a splitter) at (x,y,w,h), returning
    // the new clamped pane size (== cur when not dragging). It owns its own latch (sp_drag/sp_grab/sp_base),
    // independent of the window and scrollbar latches. `vertical` true = a vertical BAR dragged horizontally
    // (resizes WIDTH, the sidebar case); false = a horizontal bar dragged vertically (resizes HEIGHT). `before`
    // true = the resized pane sits BEFORE the handle (dragging toward the far edge GROWS it); false = after it.
    //
    // ABSOLUTE-ANCHOR model: at the press we capture the pane size (sp_base) and the mouse axis (sp_grab); each
    // frame the new size = sp_base + (axis - sp_grab) * sign. This never reads the handle's own x/y, which moves
    // under the cursor as the pane resizes — so the drag can't drift. The passed rect is used only to hit-test.
    // While hovered or dragging it sets the matching resize cursor (reset to default each frame by frame_begin).
    fn _split_drag(mut self, id: int, x: int, y: int, w: int, h: int,
                   vertical: bool, before: bool, cur: int, lo: int, hi: int) -> int {
        let over = self.mx >= x && self.mx < x + w && self.my >= y && self.my < y + h
        let allowed = self.open_popup == NONE && self.cur_win == self.hover_win
        if allowed && over {
            self.hot = id
        }
        if allowed && over && self.down && !self.was {   // press DOWN on the handle → latch the resize
            self.sp_drag = id
            if vertical {
                self.sp_grab = self.mx
            } else {
                self.sp_grab = self.my
            }
            self.sp_base = cur
        }
        var size = cur
        if self.sp_drag == id {
            if self.down {
                var axis = self.mx                       // follow even if the cursor leaves the thin band (fling-drag)
                if !vertical {
                    axis = self.my
                }
                var delta = axis - self.sp_grab
                if !before {
                    delta = 0 - delta                    // handle before the pane → dragging toward it shrinks it
                }
                size = self.sp_base + delta
                if size < lo {
                    size = lo
                }
                if size > hi {
                    size = hi
                }
            } else {
                self.sp_drag = NONE                      // released
            }
        }
        if self.hot == id || self.sp_drag == id {        // show the resize pointer while hovered/dragging
            if vertical {
                set_cursor(CURSOR_RESIZE_EW)
            } else {
                set_cursor(CURSOR_RESIZE_NS)
            }
        }
        return size
    }




    // split_release drops a held splitter latch if it belongs to `id`. The caller (std/flare) uses it when a
    // modal gates the handle so the drag can't be CARRIED while inert — without it, a latch held when a modal
    // opens would survive (the in-method release never runs while gated) and snap the pane on the next press.
    fn split_release(mut self, id: int) {
        if self.sp_drag == id {
            self.sp_drag = NONE
        }
    }




    // label draws a line of text, vertically centred in the row, and advances the cursor.
    fn label(mut self, s: string) {
        let x = self.cx
        let y = self.cy
        let w = measure_text(s, self.style.text_size)
        let ty = y + (self.style.row_h - self.style.text_size) / 2
        draw_text(s, x, ty, self.style.text_size, self.style.ink)
        self.advance(x, y, w, self.style.row_h)
    }


    // heading draws a label centre-justified across width `w` (from the cursor), a little
    // larger and in the primary ink — for section titles and centred captions.
    fn heading(mut self, s: string, w: int) {
        let x  = self.cx
        let y  = self.cy
        let sz = self.style.text_size + 4
        let tw = measure_text(s, sz)
        var tx = x + (w - tw) / 2
        if tx < x {
            tx = x
        }
        draw_text(s, tx, y + (self.style.row_h - sz) / 2, sz, self.style.ink)
        self.advance(x, y, w, self.style.row_h)
    }


    // label_right draws a label right-justified within width `w` (e.g. a value beside a name).
    fn label_right(mut self, s: string, w: int) {
        let x  = self.cx
        let y  = self.cy
        let tw = measure_text(s, self.style.text_size)
        var tx = x + w - tw
        if tx < x {
            tx = x
        }
        draw_text(s, tx, y + (self.style.row_h - self.style.text_size) / 2,
                  self.style.text_size, self.style.muted_ink)
        self.advance(x, y, w, self.style.row_h)
    }


    // muted draws secondary text (hints, captions, counts) in the muted ink — same metrics as
    // label, so it lays out and measures identically; only the colour differs.
    fn muted(mut self, s: string) {
        let x = self.cx
        let y = self.cy
        let w = measure_text(s, self.style.text_size)
        let ty = y + (self.style.row_h - self.style.text_size) / 2
        draw_text(s, x, ty, self.style.text_size, self.style.muted_ink)
        self.advance(x, y, w, self.style.row_h)
    }


    // divider draws a hairline horizontal rule across width `w` (a section separator), with a
    // little vertical breathing room above and below it.
    fn divider(mut self, w: int) {
        let x = self.cx
        let y = self.cy + self.style.pad
        fill_round(x, y, w, 1, 0, self.style.border, 255)
        self.advance(x, self.cy, w, self.style.pad * 2 + 1)
    }


    // wid computes a widget id from its label, mixed with the current id scope so that two
    // widgets with the SAME label in different scopes (e.g. a "+" button in each of many list
    // rows) get distinct ids. With the default empty scope it is exactly hash(label), so nothing
    // changes for code that never sets a scope.
    fn wid(self, label: string) -> int {
        return hash(self.id_pre + label)
    }


    // set_scope sets the id-scope prefix (std/flare drives this from its key()/list identity).
    fn set_scope(mut self, s: string) {
        self.id_pre = s
    }


    // button draws a clickable, rounded, softly-shadowed button sized to its label, with the
    // text centred; it lightens on hover and sinks a pixel while pressed. Returns true on a click.
    fn button(mut self, txt: string) -> bool {
        let id = self.wid(txt)
        let w  = measure_text(txt, self.style.text_size) + self.style.pad * 3
        let h  = self.style.row_h
        let x  = self.cx
        let y  = self.cy
        let clicked = self.press(id, x, y, w, h)
        var fill = self.style.panel
        if self.active == id {
            fill = self.style.pressed
        } else if self.hot == id {
            fill = self.style.hover
        }
        var oy = 0
        if self.active == id {
            oy = 1                       // pressed: nudge down a pixel so it feels depressed
        }
        card(x, y + oy, w, h, fill, self.style, true)
        let tw = measure_text(txt, self.style.text_size)
        let tx = x + (w - tw) / 2
        let ty = y + oy + (h - self.style.text_size) / 2
        draw_text(txt, tx, ty, self.style.text_size, self.style.ink)
        self.advance(x, y, w, h)
        if clicked {
            tape_mark("click", txt)     // recorded only when a UI tape is open
        }
        return clicked
    }


    // checkbox draws a labelled iOS-style toggle pill (track + sliding knob); returns its new
    // state (flips on click). The track turns the accent colour when on; the knob casts a shadow.
    fn checkbox(mut self, txt: string, on: bool) -> bool {
        let id  = self.wid(txt)
        let x   = self.cx
        let y   = self.cy
        let h   = self.style.row_h
        let tw  = h + h / 2          // track width (a wide pill)
        let th  = h - 12             // track height
        let clicked = self.press(id, x, y, tw, h)
        var checked = on
        if clicked {
            checked = !on
            tape_mark("toggle", txt)
        }
        let ty = y + (h - th) / 2
        var track = self.style.track
        if checked {
            track = self.style.accent
        } else if self.hot == id {
            track = self.style.hover
        }
        fill_round(x, ty, tw, th, th / 2, track, 255)    // pill track
        let kr  = th / 2 - 2
        let cyk = ty + th / 2
        var kx  = x + th / 2
        if checked {
            kx = x + tw - th / 2
        }
        shadow(kx - kr, cyk - kr + 1, kr * 2, kr * 2, kr, self.style.shadow)
        fill_circle(kx, cyk, kr, self.style.accent_ink, 255)  // sliding knob
        let lx = x + tw + self.style.pad
        draw_text(txt, lx, y + (h - self.style.text_size) / 2, self.style.text_size, self.style.ink)
        let w = tw + self.style.pad + measure_text(txt, self.style.text_size)
        self.advance(x, y, w, h)
        return checked
    }


    // slider draws a horizontal track; while dragged, the value follows the mouse.
    // The contract is the spec: the range must be non-empty (it also guards the
    // `(hi - lo)` divisions below from a divide-by-zero), and the returned value is
    // ALWAYS within [lo, hi] — including when the caller passes an out-of-range value
    // and the slider isn't being dragged (which is why `v` is clamped before return).
    fn slider(mut self, name: string, value: int, lo: int, hi: int) -> int
        requires lo < hi
        ensures result >= lo
        ensures result <= hi
    {
        let id = self.wid(name)
        let x  = self.cx
        let y  = self.cy
        let w  = 200
        self.press(id, x, y, w, self.style.row_h)     // for the hot/active side effects
        var v = value
        if self.active == id {
            var t = self.mx - x
            if t < 0 {
                t = 0
            }
            if t > w {
                t = w
            }
            v = lo + t * (hi - lo) / w
        }
        if v < lo {           // honour the postcondition even for an out-of-range input
            v = lo
        }
        if v > hi {
            v = hi
        }
        var fillw = (v - lo) * w / (hi - lo)
        if fillw < 0 {
            fillw = 0
        }
        if fillw > w {
            fillw = w
        }
        let h   = self.style.row_h
        let cyk = y + h / 2
        let th  = 6
        fill_round(x, cyk - th / 2, w, th, th / 2, self.style.track, 255)   // full track
        if fillw > 0 {
            fill_round(x, cyk - th / 2, fillw, th, th / 2, self.style.accent, 255)  // filled
        }
        let kr = 9
        let kx = x + fillw
        shadow(kx - kr, cyk - kr + 1, kr * 2, kr * 2, kr, self.style.shadow)
        fill_circle(kx, cyk, kr, self.style.accent_ink, 255)                    // draggable knob
        stroke_round(kx - kr, cyk - kr, kr * 2, kr * 2, kr, 1, self.style.accent, 180)
        self.advance(x, y, w, h)
        return v
    }


    // _del_selection cuts the selected range out of the focused field's buffer and collapses the
    // caret + anchor to its start. A no-op when there is no selection (anchor == caret).
    fn _del_selection(mut self) {
        var lo = self.sel_anchor
        var hi = self.caret
        if lo > hi {
            lo = self.caret
            hi = self.sel_anchor
        }
        if lo != hi {
            self.buf = str.cp_slice(self.buf, 0, lo) + str.cp_slice(self.buf, hi, str.cp_count(self.buf))
            self.caret = lo
            self.sel_anchor = lo
        }
    }


    // text_field is an editable single-line field. Click it to focus; type/Backspace/Delete edit;
    // Left/Right/Home/End move the caret (hold Shift to SELECT); Ctrl/Cmd+A select-all, +C/+X/+V
    // copy/cut/paste via the system clipboard; click-drag or Shift-click select with the mouse. The
    // value round-trips through your variable (like `slider`): `name = u.text_field("name", name)`.
    // Only the focused field keeps edit state (in the Ui), which is all single-line input needs.
    // _tf_edit runs one frame of INPUT for a text field occupying rect (x,y,w,h): click-to-focus,
    // drag-select, and — while focused — the full keyboard (selection-aware typing, Backspace/Delete,
    // ←/→/Home/End, Ctrl/Cmd A·C·X·V) plus horizontal scroll to keep the caret in view. Returns the
    // text to display (the live edit buffer while focused, else `value`). ENTER is the caller's to read,
    // so a deferred-paint layout (std/flare) can run input now and paint later at the solved rect.
    fn _tf_edit(mut self, id: int, x: int, y: int, w: int, h: int, value: string) -> string {
        let tx = x + self.style.pad
        let inner = w - self.style.pad * 2   // visible text width (the field minus left+right padding)
        let shift = key_down(KEY_LSHIFT) || key_down(KEY_RSHIFT)
        let cmd   = key_down(KEY_LCTRL) || key_down(KEY_RCTRL) || key_down(KEY_LSUPER) || key_down(KEY_RSUPER)
        if self.press(id, x, y, w, h) {     // click focuses, loads the value, drops the caret here
            let was_focused = self.focus == id
            if !was_focused {               // focusing a DIFFERENT field: start its scroll at 0
                self.text_off = 0
            }
            self.focus = id
            self.buf   = value
            // Map the click x to a caret (through the field's scroll). Shift-click EXTENDS the
            // current selection to the click; a plain click drops a fresh caret (collapses it).
            let cc = cp_caret_from_x(value, self.mx - tx + self.text_off, self.style.text_size)
            self.caret = cc
            if !shift || !was_focused {
                self.sel_anchor = cc
            }
        }
        // Drag-select: while the button is held over the focused field, extend the selection to the
        // cursor — the anchor stays where the press dropped it.
        if self.focus == id && self.down && self.was {
            self.caret = cp_caret_from_x(self.buf, self.mx - tx + self.text_off, self.style.text_size)
        }
        var shown = value
        if self.focus == id {
            // selection bounds (used by copy/cut); the moving end is the caret, the fixed end the anchor
            var lo = self.sel_anchor
            var hi = self.caret
            if lo > hi {
                lo = self.caret
                hi = self.sel_anchor
            }
            let has_sel = lo != hi
            if cmd && key_pressed(KEY_A) {               // Ctrl/Cmd+A — select all
                self.sel_anchor = 0
                self.caret = str.cp_count(self.buf)
            } else if cmd && key_pressed(KEY_C) {        // Ctrl/Cmd+C — copy
                if has_sel {
                    clipboard_set(str.cp_slice(self.buf, lo, hi))
                }
            } else if cmd && key_pressed(KEY_X) {        // Ctrl/Cmd+X — cut
                if has_sel {
                    clipboard_set(str.cp_slice(self.buf, lo, hi))
                    self._del_selection()
                }
            } else if cmd && key_pressed(KEY_V) {        // Ctrl/Cmd+V — paste, replacing any selection
                let p = clipboard_get()
                self._del_selection()
                if p.len() > 0 {
                    self.buf   = str.cp_insert(self.buf, self.caret, p)
                    self.caret = self.caret + str.cp_count(p)
                }
                self.sel_anchor = self.caret
            } else {
                // Printable characters replace the selection (if any), then insert at the caret.
                loop {
                    let c = char_pressed()
                    if c == 0 {
                        break
                    }
                    if c >= 32 {
                        self._del_selection()
                        self.buf   = str.cp_insert(self.buf, self.caret, from_char_code(c))
                        self.caret = self.caret + 1
                        self.sel_anchor = self.caret
                    }
                }
                // Backspace/Delete remove the selection if there is one, else one character. They
                // fire on press AND on auto-repeat while held.
                if key_pressed(KEY_BACKSPACE) || key_repeat(KEY_BACKSPACE) {
                    if self.sel_anchor != self.caret {
                        self._del_selection()
                    } else if self.caret > 0 {
                        self.buf   = str.cp_delete(self.buf, self.caret - 1)
                        self.caret = self.caret - 1
                        self.sel_anchor = self.caret
                    }
                }
                if key_pressed(KEY_DELETE) || key_repeat(KEY_DELETE) {
                    if self.sel_anchor != self.caret {
                        self._del_selection()
                    } else if self.caret < str.cp_count(self.buf) {
                        self.buf = str.cp_delete(self.buf, self.caret)
                        self.sel_anchor = self.caret
                    }
                }
                // Arrows move the caret; holding Shift EXTENDS the selection, a plain arrow COLLAPSES
                // it (to the near edge), then keeps caret == anchor.
                if key_pressed(KEY_LEFT) || key_repeat(KEY_LEFT) {
                    if !shift && self.sel_anchor != self.caret {
                        if self.sel_anchor < self.caret {
                            self.caret = self.sel_anchor
                        }
                    } else if self.caret > 0 {
                        self.caret = self.caret - 1
                    }
                    if !shift {
                        self.sel_anchor = self.caret
                    }
                }
                if key_pressed(KEY_RIGHT) || key_repeat(KEY_RIGHT) {
                    if !shift && self.sel_anchor != self.caret {
                        if self.sel_anchor > self.caret {
                            self.caret = self.sel_anchor
                        }
                    } else if self.caret < str.cp_count(self.buf) {
                        self.caret = self.caret + 1
                    }
                    if !shift {
                        self.sel_anchor = self.caret
                    }
                }
                if key_pressed(KEY_HOME) {
                    self.caret = 0
                    if !shift {
                        self.sel_anchor = 0
                    }
                }
                if key_pressed(KEY_END) {
                    self.caret = str.cp_count(self.buf)
                    if !shift {
                        self.sel_anchor = self.caret
                    }
                }
            }
            shown = self.buf
            // Keep the caret in view: scroll horizontally so its pixel x stays inside [0, inner].
            let cpx = measure_text(str.cp_prefix(shown, self.caret), self.style.text_size)
            if cpx - self.text_off > inner {     // caret past the right edge → scroll the text left
                self.text_off = cpx - inner
            }
            if cpx - self.text_off < 0 {         // caret before the left edge → scroll the text right
                self.text_off = cpx
            }
            if self.text_off < 0 {
                self.text_off = 0
            }
        }
        return shown
    }


    // _tf_draw paints a text field at rect (x,y,w,h): a recessed surface, an accent focus ring +
    // translucent selection highlight + blinking caret while focused, the value clipped to the field.
    // Pairs with _tf_edit (input) — the split lets std/flare paint at the solved rect after layout.
    fn _tf_draw(mut self, id: int, x: int, y: int, w: int, h: int, value: string) {
        let tx = x + self.style.pad
        let inner = w - self.style.pad * 2
        var shown = value
        if self.focus == id {
            shown = self.buf
        }
        var fill = self.style.pressed       // a recessed (input) surface, not a raised button
        if self.hot == id {
            fill = self.style.hover
        }
        card(x, y, w, h, fill, self.style, false)
        if self.focus == id {               // an accent focus ring while editing
            stroke_round(x, y, w, h, self.style.radius, 2, self.style.accent, 255)
        }
        // Centre the true line box (ascender+descender) in the field, and size the selection highlight
        // + caret to it — NOT to text_size, which is shorter than the glyphs' real vertical extent and
        // top-aligned, so a text_size box looks top-heavy (gap above the caps, descenders clipped).
        let lh = text_line_height(self.style.text_size)
        let ty = y + (h - lh) / 2
        var off = 0
        if self.focus == id {
            off = self.text_off
        }
        clip_push(tx, y, inner, h)              // clip text to the field so a wide value can't overflow
        if self.focus == id && self.sel_anchor != self.caret {   // translucent highlight behind the run
            var slo = self.sel_anchor
            var shi = self.caret
            if slo > shi {
                slo = self.caret
                shi = self.sel_anchor
            }
            let xlo = measure_text(str.cp_prefix(shown, slo), self.style.text_size)
            let xhi = measure_text(str.cp_prefix(shown, shi), self.style.text_size)
            fill_round(tx + xlo - off, ty, xhi - xlo, lh, 0, self.style.accent, 70)
        }
        draw_text(shown, tx - off, ty, self.style.text_size, self.style.ink)
        if self.focus == id && (self.frame / 30) % 2 == 0 {   // blinking caret at its position
            let cw = measure_text(str.cp_prefix(shown, self.caret), self.style.text_size)
            draw_rect(tx + cw - off, ty, 2, lh, self.style.accent)
        }
        clip_pop()
    }


    // _ta_row returns the index of the visual line that holds `caret` (the last line whose start is ≤ caret).
    fn _ta_row(self, vls: [VLine], caret: int) -> int {
        var i = 0
        loop {
            if i + 1 >= vls.len() {
                return i
            }
            if caret < vls[i + 1].start {
                return i
            }
            i = i + 1
        }
        return 0
    }


    // _ta_caret_x returns the caret's pixel x within its visual line (for keeping ↑/↓ on the same column).
    fn _ta_caret_x(self, vls: [VLine], caret: int) -> int {
        let row = self._ta_row(vls, caret)
        var col = caret - vls[row].start
        let len = str.cp_count(vls[row].text)
        if col > len {
            col = len
        }
        if col < 0 {
            col = 0
        }
        return measure_text(str.cp_slice(vls[row].text, 0, col), self.style.text_size)
    }


    // _ta_caret_at maps a click (mx,my) inside a text area to a flat caret index, through the vertical scroll.
    fn _ta_caret_at(self, buf: string, inner: int, tx: int, ty0: int, mx: int, my: int) -> int {
        let vls = _wrap_lines(buf, inner, self.style.text_size)
        let lh = text_line_height(self.style.text_size)
        var row = (my - ty0 + self.text_off) / lh
        if row < 0 {
            row = 0
        }
        if row >= vls.len() {
            row = vls.len() - 1
        }
        let col = cp_caret_from_x(vls[row].text, mx - tx, self.style.text_size)
        return vls[row].start + col
    }


    // _ta_line_count is how many visual lines `buf` wraps to at `inner` px — drives a text area's auto-grow.
    fn _ta_line_count(self, buf: string, inner: int) -> int {
        return _wrap_lines(buf, inner, self.style.text_size).len()
    }


    // _ta_edit runs one frame of INPUT for a MULTI-LINE text area at (x,y,w,h). Same flat code-point buffer +
    // selection + clipboard as a field, but the caret moves in 2D over WRAPPED visual lines: click/drag maps
    // (mx,my) → caret, ↑/↓ keep the column across lines, Home/End go to the visual line's edges, Shift+Enter
    // inserts a newline (plain Enter is the caller's to read — e.g. send). Vertical scroll keeps the caret in
    // view. Returns the text to show; pairs with _ta_draw so std/flare can paint at the solved rect.
    fn _ta_edit(mut self, id: int, x: int, y: int, w: int, h: int, value: string) -> string {
        let tx = x + self.style.pad
        let ty0 = y + self.style.pad
        let inner = w - self.style.pad * 2
        let lh = text_line_height(self.style.text_size)
        let shift = key_down(KEY_LSHIFT) || key_down(KEY_RSHIFT)
        let cmd   = key_down(KEY_LCTRL) || key_down(KEY_RCTRL) || key_down(KEY_LSUPER) || key_down(KEY_RSUPER)
        if self.press(id, x, y, w, h) {
            let was_focused = self.focus == id
            if !was_focused {
                self.text_off = 0
            }
            self.focus = id
            self.buf = value
            let cc = self._ta_caret_at(value, inner, tx, ty0, self.mx, self.my)
            self.caret = cc
            if !shift || !was_focused {
                self.sel_anchor = cc
            }
        }
        if self.focus == id && self.down && self.was {
            self.caret = self._ta_caret_at(self.buf, inner, tx, ty0, self.mx, self.my)
        }
        var shown = value
        if self.focus == id {
            let vls = _wrap_lines(self.buf, inner, self.style.text_size)
            if cmd && key_pressed(KEY_A) {
                self.sel_anchor = 0
                self.caret = str.cp_count(self.buf)
            } else if cmd && key_pressed(KEY_C) {
                if self.sel_anchor != self.caret {
                    var clo = self.sel_anchor
                    var chi = self.caret
                    if clo > chi {
                        clo = self.caret
                        chi = self.sel_anchor
                    }
                    clipboard_set(str.cp_slice(self.buf, clo, chi))
                }
            } else if cmd && key_pressed(KEY_X) {
                if self.sel_anchor != self.caret {
                    var xlo = self.sel_anchor
                    var xhi = self.caret
                    if xlo > xhi {
                        xlo = self.caret
                        xhi = self.sel_anchor
                    }
                    clipboard_set(str.cp_slice(self.buf, xlo, xhi))
                    self._del_selection()
                }
            } else if cmd && key_pressed(KEY_V) {
                let p = clipboard_get()
                self._del_selection()
                if p.len() > 0 {
                    self.buf   = str.cp_insert(self.buf, self.caret, p)
                    self.caret = self.caret + str.cp_count(p)
                }
                self.sel_anchor = self.caret
            } else {
                loop {
                    let c = char_pressed()
                    if c == 0 {
                        break
                    }
                    if c >= 32 {
                        self._del_selection()
                        self.buf   = str.cp_insert(self.buf, self.caret, from_char_code(c))
                        self.caret = self.caret + 1
                        self.sel_anchor = self.caret
                    }
                }
                if key_pressed(KEY_ENTER) && shift {   // Shift+Enter inserts a newline; plain Enter = caller's
                    self._del_selection()
                    self.buf   = str.cp_insert(self.buf, self.caret, "\n")
                    self.caret = self.caret + 1
                    self.sel_anchor = self.caret
                }
                if key_pressed(KEY_BACKSPACE) || key_repeat(KEY_BACKSPACE) {
                    if self.sel_anchor != self.caret {
                        self._del_selection()
                    } else if self.caret > 0 {
                        self.buf   = str.cp_delete(self.buf, self.caret - 1)
                        self.caret = self.caret - 1
                        self.sel_anchor = self.caret
                    }
                }
                if key_pressed(KEY_DELETE) || key_repeat(KEY_DELETE) {
                    if self.sel_anchor != self.caret {
                        self._del_selection()
                    } else if self.caret < str.cp_count(self.buf) {
                        self.buf = str.cp_delete(self.buf, self.caret)
                        self.sel_anchor = self.caret
                    }
                }
                if key_pressed(KEY_LEFT) || key_repeat(KEY_LEFT) {
                    if !shift && self.sel_anchor != self.caret {
                        if self.sel_anchor < self.caret {
                            self.caret = self.sel_anchor
                        }
                    } else if self.caret > 0 {
                        self.caret = self.caret - 1
                    }
                    if !shift {
                        self.sel_anchor = self.caret
                    }
                }
                if key_pressed(KEY_RIGHT) || key_repeat(KEY_RIGHT) {
                    if !shift && self.sel_anchor != self.caret {
                        if self.sel_anchor > self.caret {
                            self.caret = self.sel_anchor
                        }
                    } else if self.caret < str.cp_count(self.buf) {
                        self.caret = self.caret + 1
                    }
                    if !shift {
                        self.sel_anchor = self.caret
                    }
                }
                if key_pressed(KEY_UP) || key_repeat(KEY_UP) {
                    let row = self._ta_row(vls, self.caret)
                    if row > 0 {
                        let cx = self._ta_caret_x(vls, self.caret)
                        self.caret = vls[row - 1].start + cp_caret_from_x(vls[row - 1].text, cx, self.style.text_size)
                    }
                    if !shift {
                        self.sel_anchor = self.caret
                    }
                }
                if key_pressed(KEY_DOWN) || key_repeat(KEY_DOWN) {
                    let row = self._ta_row(vls, self.caret)
                    if row + 1 < vls.len() {
                        let cx = self._ta_caret_x(vls, self.caret)
                        self.caret = vls[row + 1].start + cp_caret_from_x(vls[row + 1].text, cx, self.style.text_size)
                    }
                    if !shift {
                        self.sel_anchor = self.caret
                    }
                }
                if key_pressed(KEY_HOME) {
                    let row = self._ta_row(vls, self.caret)
                    self.caret = vls[row].start
                    if !shift {
                        self.sel_anchor = self.caret
                    }
                }
                if key_pressed(KEY_END) {
                    let row = self._ta_row(vls, self.caret)
                    self.caret = vls[row].start + str.cp_count(vls[row].text)
                    if !shift {
                        self.sel_anchor = self.caret
                    }
                }
            }
            shown = self.buf
            let vls2 = _wrap_lines(self.buf, inner, self.style.text_size)
            let crow = self._ta_row(vls2, self.caret)
            let cy = crow * lh
            let box = h - self.style.pad * 2
            if cy - self.text_off > box - lh {
                self.text_off = cy - (box - lh)
            }
            if cy - self.text_off < 0 {
                self.text_off = cy
            }
            if self.text_off < 0 {
                self.text_off = 0
            }
        }
        return shown
    }


    // _ta_draw paints a multi-line text area: a recessed surface + focus ring, the wrapped visual lines with
    // a translucent selection highlight, and a blinking caret in 2D — all clipped to the box and shifted by
    // the vertical scroll. Pairs with _ta_edit (the input/paint split lets std/flare paint at the solved rect).
    fn _ta_draw(mut self, id: int, x: int, y: int, w: int, h: int, value: string) {
        let tx = x + self.style.pad
        let ty0 = y + self.style.pad
        let inner = w - self.style.pad * 2
        let size = self.style.text_size
        let lh = text_line_height(size)
        var shown = value
        if self.focus == id {
            shown = self.buf
        }
        var fill = self.style.pressed
        if self.hot == id {
            fill = self.style.hover
        }
        card(x, y, w, h, fill, self.style, false)
        if self.focus == id {
            stroke_round(x, y, w, h, self.style.radius, 2, self.style.accent, 255)
        }
        var voff = 0
        if self.focus == id {
            voff = self.text_off
        }
        let vls = _wrap_lines(shown, inner, size)
        var lo = self.sel_anchor
        var hi = self.caret
        if lo > hi {
            lo = self.caret
            hi = self.sel_anchor
        }
        clip_push(x, y, w, h)
        var i = 0
        loop {
            if i == vls.len() {
                break
            }
            let ly = ty0 + i * lh - voff
            let ls = vls[i].start
            let le = ls + str.cp_count(vls[i].text)
            if self.focus == id && hi > lo {
                var a = lo
                if a < ls {
                    a = ls
                }
                var b = hi
                if b > le {
                    b = le
                }
                if b > a {
                    let xa = measure_text(str.cp_slice(vls[i].text, 0, a - ls), size)
                    let xb = measure_text(str.cp_slice(vls[i].text, 0, b - ls), size)
                    fill_round(tx + xa, ly, xb - xa, lh, 0, self.style.accent, 70)
                }
            }
            draw_text(vls[i].text, tx, ly, size, self.style.ink)
            i = i + 1
        }
        if self.focus == id && (self.frame / 30) % 2 == 0 {
            let crow = self._ta_row(vls, self.caret)
            var cc = self.caret - vls[crow].start
            let clen = str.cp_count(vls[crow].text)
            if cc > clen {
                cc = clen
            }
            if cc < 0 {
                cc = 0
            }
            let cxp = measure_text(str.cp_slice(vls[crow].text, 0, cc), size)
            draw_rect(tx + cxp, ty0 + crow * lh - voff, 2, lh, self.style.accent)
        }
        clip_pop()
    }


    // _code_input runs one frame of INPUT for a READ-ONLY, selectable monospace code panel at (x,y,w,h).
    // It reuses the same focus/caret/sel_anchor/clipboard machinery as the editable widgets, but with no
    // mutation of the text: drag-select (the anchor drops on the press DOWN-edge so a first drag selects),
    // Ctrl/Cmd+A select-all, Ctrl/Cmd+C copy. The mono font must be the active font (for the (mx,my)→caret
    // hit-test to match the painted glyphs). The caller (std/flare) paints the selection + spans separately
    // at the solved rect; pairing input here with paint there is the same split _ta_edit/_ta_draw use.
    fn _code_input(mut self, id: int, x: int, y: int, w: int, h: int, src: string, cs: int, lh: int, pad: int) {
        let tx = x + pad
        let ty0 = y + pad
        let shift = key_down(KEY_LSHIFT) || key_down(KEY_RSHIFT)
        let cmd   = key_down(KEY_LCTRL) || key_down(KEY_RCTRL) || key_down(KEY_LSUPER) || key_down(KEY_RSUPER)
        let _ = self.press(id, x, y, w, h)            // register hot/active so the panel owns its hover + clicks
        if self.pressed_down(id, x, y, w, h) {        // press DOWN: focus this panel and drop the anchor here
            self.focus = id
            self.buf   = src
            let cc = code_caret_at(src, tx, ty0, cs, lh, self.mx, self.my)
            self.caret = cc
            if !shift {
                self.sel_anchor = cc
            }
        }
        if self.focus == id && self.down && self.was {   // drag: extend the selection to the cursor
            self.caret = code_caret_at(self.buf, tx, ty0, cs, lh, self.mx, self.my)
        }
        if self.focus == id {
            if cmd && key_pressed(KEY_A) {               // Ctrl/Cmd+A — select the whole block
                self.sel_anchor = 0
                self.caret = str.cp_count(self.buf)
            } else if cmd && key_pressed(KEY_C) {        // Ctrl/Cmd+C — copy the selection
                if self.sel_anchor != self.caret {
                    var lo = self.sel_anchor
                    var hi = self.caret
                    if lo > hi {
                        lo = self.caret
                        hi = self.sel_anchor
                    }
                    clipboard_set(str.cp_slice(self.buf, lo, hi))
                }
            }
            loop {                                       // read-only: drain typed chars so they can't leak
                let c = char_pressed()                   // to a field focused later this frame
                if c == 0 {
                    break
                }
            }
        }
    }


    // text_field is the immediate-mode field: input + paint at the cursor; Enter commits (defocuses).
    fn text_field(mut self, key: string, value: string) -> string {
        let id = self.wid(key)
        let x  = self.cx
        let y  = self.cy
        let w  = 240
        let h  = self.style.row_h
        let shown = self._tf_edit(id, x, y, w, h, value)
        if self.focus == id && key_pressed(KEY_ENTER) {   // single-line field: Enter commits + defocuses
            self.focus = NONE
        }
        self._tf_draw(id, x, y, w, h, value)
        self.advance(x, y, w, h)
        return shown
    }


    // window_begin opens a draggable, z-ordered window and returns true (it is always
    // "open" for now). Widgets described between it and window_end lay out inside the
    // window, on its own layer, and only interact when it is the window under the mouse.
    // Clicking a window raises it to the front; dragging its title bar moves it. Position
    // and z-order persist across frames in the registry, so the window stays where you
    // left it. Pair every call with window_end.
    //
    // The postcondition is load-bearing: window_begin must leave a current window set, since
    // window_end relies on `cur_win` to know which record to size and close. The old six-array
    // length invariant is gone — one Window struct per id can't desync, so that whole class of
    // mis-indexing bug is now structural (unrepresentable) rather than guarded at runtime.
    fn window_begin(mut self, title: string) -> bool
        ensures self.cur_win != NONE
    {
        let id = self.wid(title)
        if !self.wins.has(id) {             // first sighting: register with a cascade
            let k = self.wins.size()
            self.wins.set(id, Window { x: 40 + k * 24, y: 40 + k * 24, w: 220, h: 180, z: self.z_top })
            self.z_top = self.z_top + 1
        }
        // Pull this window's persistent record into a local, mutate it here, and write it back
        // once below. `win = w` deep-copies the value-struct out of the map (value semantics), so
        // the local and the registry are independent owners.
        var win = Window { x: 0, y: 0, w: 0, h: 0, z: 0 }
        match self.wins.get(id) {
            case Some(w) { win = w }
            case None {}
        }

        // Save the background cursor so window_end can resume it.
        self.save_cx      = self.cx
        self.save_cy      = self.cy
        self.save_line_x  = self.line_x
        self.save_row_max = self.row_max
        self.cur_win = id
        let bar_h = self.style.row_h

        // A fresh press on the hovered window raises it to the front; if that press
        // landed on the title bar, begin a drag (remember the grab offset). Suppressed
        // while a menu is open (it's modal).
        if self.hover_win == id && self.down && !self.was && self.open_popup == NONE {
            win.z = self.z_top
            self.z_top = self.z_top + 1
            tape_mark("focus", title)
            if self.mx >= win.x && self.mx < win.x + win.w && self.my >= win.y && self.my < win.y + bar_h {
                self.drag_id = id
                self.drag_dx = self.mx - win.x
                self.drag_dy = self.my - win.y
            }
        }
        // Carry an in-progress drag, or end it on release.
        if self.drag_id == id {
            if self.down {
                win.x = self.mx - self.drag_dx
                win.y = self.my - self.drag_dy
            } else {
                self.drag_id = NONE
            }
        }
        // Persist this frame's mutations (z-raise, drag move) back to the registry.
        self.wins.set(id, win)

        let wx = win.x
        let wy = win.y
        let ww = win.w
        let wh = win.h
        set_layer(win.z + 1)                // windows sit above the background (layer 0)

        shadow(wx, wy + 4, ww, wh, self.style.radius, 110)        // float the window off the bg
        fill_round(wx, wy, ww, wh, self.style.radius, self.style.panel, 255)
        stroke_round(wx, wy, ww, wh, self.style.radius, 1, self.style.border, 160)
        var barcol = shade(self.style.panel, 8)
        if self.hover_win == id {
            barcol = self.style.accent                            // focused window: accent titlebar
        }
        fill_round(wx, wy, ww, bar_h, self.style.radius, barcol, 255)   // rounded top, square below
        fill_round(wx, wy + bar_h - self.style.radius, ww, self.style.radius, 0, barcol, 255)
        var titlecol = self.style.ink
        if self.hover_win == id {
            titlecol = self.style.accent_ink
        }
        draw_text(title, wx + self.style.pad, wy + (bar_h - self.style.text_size) / 2,
                  self.style.text_size, titlecol)

        // Clip the content to the body so anything that overflows is masked rather than
        // bleeding over a neighbouring window. window_end pops this.
        clip_push(wx, wy + bar_h, ww, wh - bar_h)

        // Park the layout cursor in the window's content area, and start tracking the
        // content extent for auto-sizing (applied next frame in window_end).
        self.cur_title_w = measure_text(title, self.style.text_size) + self.style.pad * 2
        self.line_x    = wx + self.style.pad
        self.cx        = self.line_x
        self.cy        = wy + bar_h + self.style.pad
        self.row_max   = self.cy
        self.content_x = self.cx
        self.content_y = self.cy
        return true
    }


    // window_end closes the current window: ends the content clip, sizes the window to
    // fit the widgets it held (taking effect next frame — the same last-frame trick used
    // for input routing), drops back to the background layer, and restores the cursor.
    fn window_end(mut self) {
        clip_pop()
        let id = self.cur_win
        var win = Window { x: 0, y: 0, w: 0, h: 0, z: 0 }
        match self.wins.get(id) {
            case Some(w) { win = w }
            case None {}
        }
        let bar_h = self.style.row_h

        var nw = self.content_x - win.x + self.style.pad   // fit content width, but never
        if nw < self.cur_title_w {                         // narrower than the title needs
            nw = self.cur_title_w
        }
        var nh = self.content_y - win.y + self.style.pad
        let min_h = bar_h + self.style.pad
        if nh < min_h {
            nh = min_h
        }
        win.w = nw
        win.h = nh
        self.wins.set(id, win)

        self.cur_win = NONE
        set_layer(0)
        self.cx      = self.save_cx
        self.cy      = self.save_cy
        self.line_x  = self.save_line_x
        self.row_max = self.save_row_max
    }


    // menu_begin draws a dropdown header button and returns true while its menu is open
    // (click the header to toggle). When open, the items described before menu_end lay
    // out as a floating list on the top layer, the menu is modal (everything else inert),
    // and a click on an item or anywhere outside dismisses it. Usage:
    //   if u.menu_begin("File") { if u.menu_item("Open") { ... } }
    //   u.menu_end()
    fn menu_begin(mut self, label: string) -> bool {
        let id = self.wid(label)
        let x  = self.cx
        let y  = self.cy
        let w  = measure_text(label, self.style.text_size) + self.style.pad * 2
        let h  = self.style.row_h
        let over_header = self.mx >= x && self.mx < x + w && self.my >= y && self.my < y + h

        if self.down && !self.was {
            if over_header {                    // toggle this menu open/closed
                if self.open_popup == id {
                    self.open_popup = NONE
                } else {
                    self.open_popup = id
                }
            } else if self.open_popup == id {   // press elsewhere while open: dismiss unless
                let on_items = self.mx >= self.pop_x && self.mx < self.pop_x + MENU_W &&
                               self.my >= self.pop_y0 && self.my < self.pop_y   // on the items
                if !on_items {
                    self.open_popup = NONE
                }
            }
        }

        var fill = self.style.panel
        if self.open_popup == id {
            fill = self.style.accent
        } else if over_header {
            fill = self.style.hover
        }
        card(x, y, w, h, fill, self.style, true)
        var hcol = self.style.ink
        if self.open_popup == id {
            hcol = self.style.accent_ink
        }
        draw_text(label, x + self.style.pad, y + (h - self.style.text_size) / 2, self.style.text_size, hcol)
        self.advance(x, y, w, h)

        if self.open_popup != id {
            return false
        }
        // Open: start the floating item list just below the header, on the top layer.
        self.pop_hx = x
        self.pop_hy = y
        self.pop_hw = w
        self.pop_x  = x
        self.pop_y0 = y + h
        self.pop_y  = y + h
        set_layer(POPUP_LAYER)
        return true
    }


    // menu_item draws one selectable row in the open menu; returns true when clicked
    // (which also closes the menu). Only call it between menu_begin returning true and
    // menu_end.
    fn menu_item(mut self, label: string) -> bool {
        let x = self.pop_x
        let y = self.pop_y
        let w = MENU_W
        let h = self.style.row_h
        let over = self.mx >= x && self.mx < x + w && self.my >= y && self.my < y + h
        var fill = self.style.panel
        var itemink = self.style.ink
        if over {
            fill = self.style.accent          // selection highlight
            itemink = self.style.accent_ink
        }
        fill_round(x, y, w, h, 0, fill, 255)  // square so items tile into one list
        draw_text(label, x + self.style.pad, y + (h - self.style.text_size) / 2, self.style.text_size, itemink)
        self.pop_y = self.pop_y + h
        var clicked = false
        if over && self.down && !self.was {
            clicked = true
            self.open_popup = NONE          // selecting closes the menu
            tape_mark("menu", label)
        }
        return clicked
    }


    // menu_end closes the menu scope, dropping back to the background draw layer.
    fn menu_end(mut self) {
        set_layer(0)
    }


    // hovered reports whether the most recent widget with this label is under the mouse
    // (handy for driving a tooltip). False while a menu is open.
    fn hovered(self, label: string) -> bool {
        return self.hot == self.wid(label)
    }


    // tooltip draws a small floating box of text near the mouse, on the top layer. Call
    // it conditionally, e.g. `if u.hovered("Save") { u.tooltip("Save the file") }`.
    fn tooltip(self, text: string) {
        let w = measure_text(text, self.style.text_size) + self.style.pad * 2
        let h = self.style.row_h
        let x = self.mx + 12
        let y = self.my + 12
        set_layer(POPUP_LAYER)
        shadow(x, y + 2, w, h, self.style.radius, 110)
        fill_round(x, y, w, h, self.style.radius, self.style.pressed, 255)
        stroke_round(x, y, w, h, self.style.radius, 1, self.style.border, 160)
        draw_text(text, x + self.style.pad, y + (h - self.style.text_size) / 2, self.style.text_size, self.style.ink)
        set_layer(0)
    }


    // scroll_begin opens a scrolling viewport `w` by `h` at the cursor: the widgets between it and
    // scroll_end are clipped to the viewport and shifted by the current scroll offset, which the
    // mouse wheel (over the viewport) and a draggable scrollbar adjust. One region at a time; the
    // offset persists across frames. Pair with scroll_end.
    fn scroll_begin(mut self, w: int, h: int) {
        let vx = self.cx
        let vy = self.cy
        self.sc_x = vx
        self.sc_y = vy
        self.sc_w = w
        self.sc_h = h
        self.sc_line_x = self.line_x        // remember the enclosing margin for scroll_end

        // Wheel scrolling while the pointer is over the viewport (a closed menu is modal).
        let over = self.mx >= vx && self.mx < vx + w && self.my >= vy && self.my < vy + h
        if over && self.open_popup == NONE {
            self.sc_off = self.sc_off - mouse_wheel() * 28
        }
        if self.sc_off < 0 {
            self.sc_off = 0
        }
        if self.sc_off > self.sc_max {
            self.sc_off = self.sc_max       // sc_max is last frame's content overflow
        }

        clip_push(vx, vy, w, h)
        // Park the layout cursor at the top of the content, shifted up by the scroll offset.
        self.line_x  = vx
        self.cx      = vx
        self.cy      = vy - self.sc_off
        self.row_max = self.cy
    }


    // scroll_end closes the viewport: it measures the content laid out since scroll_begin, updates
    // the scrollable range, draws (and lets you drag) the scrollbar, and parks the cursor below.
    fn scroll_end(mut self) {
        clip_pop()
        let vx = self.sc_x
        let vy = self.sc_y
        let vw = self.sc_w
        let vh = self.sc_h
        let content_h = self.row_max - (vy - self.sc_off)   // total content height this frame
        var maxoff = content_h - vh
        if maxoff < 0 {
            maxoff = 0
        }
        self.sc_max = maxoff

        if maxoff > 0 {
            let barw = 8
            let bx   = vx + vw - barw
            // Track.
            fill_round(bx, vy, barw, vh, barw / 2, self.style.track, 200)
            // Thumb sized to the visible fraction, positioned by the offset.
            var th = vh * vh / content_h
            if th < 24 {
                th = 24
            }
            // Drag handling (capture before computing ty so dragging is responsive this frame).
            var ty = vy + self.sc_off * (vh - th) / maxoff
            let over_thumb = self.mx >= bx && self.mx < bx + barw && self.my >= ty && self.my < ty + th
            if self.sc_drag {
                if !self.down {
                    self.sc_drag = false
                } else {
                    let want = self.my - self.sc_drag_dy - vy
                    self.sc_off = want * maxoff / (vh - th)
                }
            } else if over_thumb && self.down && !self.was {
                self.sc_drag = true
                self.sc_drag_dy = self.my - ty
            }
            if self.sc_off < 0 {
                self.sc_off = 0
            }
            if self.sc_off > maxoff {
                self.sc_off = maxoff
            }
            ty = vy + self.sc_off * (vh - th) / maxoff
            var thumbcol = self.style.muted_ink
            if self.sc_drag || over_thumb {
                thumbcol = self.style.accent
            }
            fill_round(bx, ty, barw, th, barw / 2, thumbcol, 255)
        }

        // Restore the enclosing margin and drop the cursor below the viewport.
        self.line_x  = self.sc_line_x
        self.cx      = self.sc_line_x
        self.cy      = vy + vh + self.style.pad
        self.row_max = self.cy
    }


    // end finalizes the frame. A no-op today; reserved for clearing stale per-widget state
    // as the toolkit grows.
    fn end(mut self) {
        return
    }
}


// themed returns a fresh Ui context using the given theme.
fn themed(style: Style) -> Ui {
    return Ui {
        cx: 0, cy: 0,
        line_x: 0, row_max: 0,
        last_x: 0, last_y: 0, last_w: 0,
        mx: 0, my: 0,
        down: false, was: false,
        hot: NONE, active: NONE, id_pre: "",
        focus: NONE, buf: "", caret: 0, sel_anchor: 0, text_off: 0, frame: 0,
        wins: map.Map<int, Window>{ buckets: [], count: 0 },
        z_top: 1, hover_win: NONE, cur_win: NONE,
        drag_id: NONE, drag_dx: 0, drag_dy: 0,
        save_cx: 0, save_cy: 0, save_line_x: 0, save_row_max: 0,
        content_x: 0, content_y: 0, cur_title_w: 0,
        open_popup: NONE, pop_x: 0, pop_y: 0, pop_y0: 0,
        pop_hx: 0, pop_hy: 0, pop_hw: 0,
        sc_off: 0, sc_max: 0, sc_x: 0, sc_y: 0, sc_w: 0, sc_h: 0,
        sc_line_x: 0, sc_drag: false, sc_drag_dy: 0,
        sp_drag: NONE, sp_grab: 0, sp_base: 0,
        style: style
    }
}


// new returns a fresh Ui context with the default (dark) theme. Hold it as a `var`
// and thread it through the loop.
fn new() -> Ui {
    return themed(dark())
}
