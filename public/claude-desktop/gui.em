// gui.em — a Claude Desktop look-alike written in Ember (Phase 2 of the acid test).
//
// The transport is the one C library Ember borrows (libcurl, via `http_post`); the GUI is the
// raylib immediate-mode backend (window_open / frame_begin / fill_round / draw_text / …). Every
// pixel of layout and all of the JSON handling are pure Ember.
//
//   make net-graphics
//   export ANTHROPIC_API_KEY=sk-ant-...
//   build/emberc-net-gfx --emit=run public/claude-desktop/gui.em

import "std/string" as str

extern "c" {
    fn http_post(url: string, headers: string, body: string) -> string
}


// recv / try_recv hand a channel value back as an Option (Some while values flow, None once the
// channel is closed and drained / empty) — the async transport below polls the fetch worker with it.
enum Option<T> {
    Some(value: T)
    None
}


// raylib key codes (text input).
let KEY_ENTER     = 257
let KEY_BACKSPACE = 259
let KEY_RIGHT     = 262
let KEY_LEFT      = 263
let KEY_DELETE    = 261
let KEY_HOME      = 268
let KEY_END       = 269
let KEY_ESCAPE    = 256
let KEY_SUPER_L   = 343   // left ⌘ (macOS)
let KEY_SUPER_R   = 347
let KEY_CTRL_L    = 341
let KEY_SHIFT_L   = 340   // selection-extend modifier (shift+arrows / shift+click)
let KEY_SHIFT_R   = 344
let KEY_A         = 65    // ⌘A select-all
let KEY_C         = 67    // ⌘C copy
let KEY_X         = 88    // ⌘X cut
let KEY_V         = 86
let KEY_N         = 78
let KEY_EQUAL     = 61    // the +/= key
let KEY_MINUS     = 45
let KEY_COMMA     = 44


// A single conversation turn. role 0 = the user, 1 = Claude. Arrays of these are the chat history.
struct Msg {
    role: int
    text: string
}






// rgb packs an 0xRRGGBB colour the way the graphics backend wants it.
fn rgb(r: int, g: int, b: int) -> int {
    return r * 65536 + g * 256 + b
}






fn hex_digit(n: int) -> string {
    if n < 10 {
        return from_char_code(48 + n)
    }
    return from_char_code(97 + (n - 10))
}






fn hex_val(c: string) -> int {
    let k = char_code(c)
    if k >= 48 && k <= 57 {
        return k - 48
    }
    if k >= 97 && k <= 102 {
        return k - 97 + 10
    }
    if k >= 65 && k <= 70 {
        return k - 65 + 10
    }
    return 0
}






// json_escape escapes a string for embedding inside a JSON double-quoted value.
fn json_escape(s: string) -> string {
    let cs = s.chars()
    var out: [string] = []
    var i = 0
    loop {
        if i == cs.len() {
            return concat(out)
        }
        let c = cs[i]
        let code = char_code(c)
        if c == "\"" {
            out.append("\\\"")
        } else if c == "\\" {
            out.append("\\\\")
        } else if code == 10 {
            out.append("\\n")
        } else if code == 13 {
            out.append("\\r")
        } else if code == 9 {
            out.append("\\t")
        } else if code < 32 {
            out.append("\\u00" + hex_digit(code / 16) + hex_digit(code))
        } else {
            out.append(c)
        }
        i = i + 1
    }
    return concat(out)
}






// extract_text decodes the assistant's reply from a Messages-API response (the first `"text":"…"`
// block), or returns the raw response when there is no text block (e.g. an API error).
fn extract_text(resp: string) -> string {
    var parts = resp.split("\"text\":\"")
    var prefix = ""
    if parts.len() < 2 {
        // No assistant text — this is an API error envelope (or a transport error). Surface its
        // "message" cleanly with a marker instead of dumping the raw JSON at the user.
        parts = resp.split("\"message\":\"")
        if parts.len() < 2 {
            return resp
        }
        prefix = "API error: "
    }
    let cs = parts[1].chars()
    var out: [string] = []
    if prefix.len() > 0 {
        out.append(prefix)
    }
    var i = 0
    loop {
        if i == cs.len() {
            return concat(out)
        }
        let c = cs[i]
        if c == "\\" {
            i = i + 1
            if i == cs.len() {
                return concat(out)
            }
            let e = cs[i]
            if e == "n" {
                out.append(from_char_code(10))
            } else if e == "t" {
                out.append(from_char_code(9))
            } else if e == "r" {
                out.append(from_char_code(13))
            } else if e == "\"" {
                out.append("\"")
            } else if e == "\\" {
                out.append("\\")
            } else if e == "/" {
                out.append("/")
            } else if e == "u" && i + 4 < cs.len() {
                let cp = hex_val(cs[i + 1]) * 4096 + hex_val(cs[i + 2]) * 256 +
                         hex_val(cs[i + 3]) * 16 + hex_val(cs[i + 4])
                out.append(from_char_code(cp))
                i = i + 4
            } else {
                out.append(e)
            }
        } else if c == "\"" {
            return concat(out)
        } else {
            out.append(c)
        }
        i = i + 1
    }
    return concat(out)
}






// join_commas joins string parts with a comma — the JSON array separator.
fn join_commas(parts: [string]) -> string {
    var out = ""
    var i = 0
    loop {
        if i == parts.len() {
            return out
        }
        if i > 0 {
            out = out + ","
        }
        out = out + parts[i]
        i = i + 1
    }
    return out
}






// build_request assembles the full multi-turn Messages-API request body from the conversation.


fn build_request(model: string, max_tokens: int, system: string, convo: [Msg]) -> string {
    var msgs: [string] = []
    var i = 0
    loop {
        if i == convo.len() {
            break
        }
        var rname = "user"
        if convo[i].role == 1 {
            rname = "assistant"
        }
        let esc = json_escape(convo[i].text)
        msgs.append("\{\"role\":\"{rname}\",\"content\":\"{esc}\"\}")
        i = i + 1
    }
    let joined = join_commas(msgs)
    var sys = ""
    if system.len() > 0 {                    // optional system prompt clause
        let se = json_escape(system)
        sys = ",\"system\":\"{se}\""
    }
    // No `temperature`: it is deprecated for the current models (the API rejects it), so we send
    // the model default. (The Temperature setting was removed for the same reason.)
    return "\{\"model\":\"{model}\",\"max_tokens\":{max_tokens}{sys},\"messages\":[{joined}]\}"
}






// fetch_worker is the async transport: a long-lived fiber (one `spawn`, so no per-message thread
// churn) that owns the blocking HTTPS round-trip. It parks on `req_ch` waiting for a request body,
// runs `http_post` + `extract_text` on its own OS thread (the parallel build) so the render loop on
// the main thread never stalls, and hands the reply back on `resp_ch`. The main loop closes `req_ch`
// at shutdown, which wakes the `recv` with None and lets the worker — and the nursery — finish.
fn fetch_worker(api_key: string, req_ch: Channel<string>, resp_ch: Channel<string>) {
    let headers = "content-type: application/json\nanthropic-version: 2023-06-01\nx-api-key: {api_key}"
    loop {
        match recv(req_ch) {
            case Some(body) {
                let resp = http_post("https://api.anthropic.com/v1/messages", headers, body)
                send(resp_ch, extract_text(resp))
            }
            case None {
                break
            }
        }
    }
}




// max_tokens for the settings preset (index → API value). Used at submit time to build the request
// body that is dispatched to the worker.
fn max_tokens_for(idx: int) -> int {
    if idx == 1 {
        return 2048
    }
    if idx == 2 {
        return 4096
    }
    if idx == 3 {
        return 8192
    }
    return 1024
}




// caret_from_x returns the code-point index whose boundary is nearest pixel offset `relx`
// (measured from the text's left edge), so a click lands the caret between the right glyphs.
fn caret_from_x(s: string, relx: int, size: int) -> int {
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
        let w = measure_text(str.cp_prefix(s, i), size)
        var d = relx - w
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






// wrap_text breaks `text` into lines no wider than `max_w` pixels at font size `size`, honouring
// existing newlines. (Greedy word wrap; a single word wider than the column is left to overflow.)
fn wrap_text(text: string, max_w: int, size: int) -> [string] {
    let paras = text.split(from_char_code(10))
    var lines: [string] = []
    var p = 0
    loop {
        if p == paras.len() {
            return lines
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






// msg_height returns the pixel height a message block occupies in a column `col_w` wide.
// A rendered chunk of an assistant reply: either flowing prose or a fenced code block.
struct Seg {
    is_code: bool
    text: string
}






// lstrip drops leading ASCII spaces (so an indented ``` fence is still recognised).
fn lstrip(s: string) -> string {
    let cs = s.chars()
    var i = 0
    loop {
        if i == cs.len() || cs[i] != " " {
            break
        }
        i = i + 1
    }
    var out: [string] = []
    loop {
        if i == cs.len() {
            return concat(out)
        }
        out.append(cs[i])
        i = i + 1
    }
    return concat(out)
}






// starts_fence reports whether a line opens/closes a Markdown code fence (``` …).
fn starts_fence(ln: string) -> bool {
    let cs = lstrip(ln).chars()
    return cs.len() >= 3 && cs[0] == "`" && cs[1] == "`" && cs[2] == "`"
}






// join_lines rejoins lines with newlines (the inverse of split on '\n').
fn join_lines(arr: [string]) -> string {
    var out = ""
    var i = 0
    loop {
        if i == arr.len() {
            return out
        }
        if i > 0 {
            out = out + from_char_code(10)
        }
        out = out + arr[i]
        i = i + 1
    }
    return out
}






// is_blank reports whether s is empty or only whitespace.
fn is_blank(s: string) -> bool {
    let cs = s.chars()
    var i = 0
    loop {
        if i == cs.len() {
            return true
        }
        let code = char_code(cs[i])
        if code != 32 && code != 9 && code != 10 && code != 13 {
            return false
        }
        i = i + 1
    }
    return true
}






// split_segments parses an assistant reply into alternating prose / fenced-code segments.
fn split_segments(text: string) -> [Seg] {
    let lines = text.split(from_char_code(10))
    var segs: [Seg] = []
    var cur: [string] = []
    var in_code = false
    var i = 0
    loop {
        if i == lines.len() {
            break
        }
        if starts_fence(lines[i]) {
            if cur.len() > 0 {
                let joined = join_lines(cur)
                if in_code || !is_blank(joined) {
                    segs.append(Seg { is_code: in_code, text: joined })
                }
                cur = []
            }
            in_code = !in_code
        } else {
            cur.append(lines[i])
        }
        i = i + 1
    }
    if cur.len() > 0 {
        let joined = join_lines(cur)
        if in_code || !is_blank(joined) {
            segs.append(Seg { is_code: in_code, text: joined })
        }
    }
    return segs
}






// seg_height is the pixel height of one rendered segment (the single source of truth shared by
// msg_height and draw_segment, so the scroll measurement can never drift from what's drawn).
fn seg_height(seg: Seg, inner: int, size: int, line_h: int) -> int {
    if seg.is_code {
        let nlines = seg.text.split(from_char_code(10)).len()
        return nlines * (line_h - 4) + 24
    }
    return wrap_text(seg.text, inner, size).len() * line_h
}






// draw_segment renders one segment at (x,y) in `inner` px and returns its height. Prose flows
// (word-wrapped); a code block is a rounded dark card with preserved whitespace, no wrapping.
fn draw_segment(seg: Seg, x: int, y: int, inner: int, size: int, line_h: int, th: Theme, mono: int,
                mx: int, my: int, do_click: bool) -> int {
    if seg.is_code {
        let csize = size - 2
        let clh   = line_h - 4
        let pad   = 12
        let lines = seg.text.split(from_char_code(10))
        let h = lines.len() * clh + 24
        fill_round(x, y, inner, h, 8, th.code_bg, 255)
        stroke_round(x, y, inner, h, 8, 1, th.code_border, 180)
        clip_push(x, y, inner, h)
        set_font(mono)                       // code in a monospace face
        var j = 0
        loop {
            if j == lines.len() {
                break
            }
            draw_text(lines[j], x + pad, y + pad + j * clh, csize, th.code_ink)
            j = j + 1
        }
        set_font(0)                          // back to the body font
        clip_pop()
        // a Copy button on top of the card (drawn last so code text never covers it)
        let bw = 52
        let bh = 22
        let bx = x + inner - bw - 8
        let by = y + 8
        let over = hit_rect(mx, my, bx, by, bw, bh)
        var bfill = th.code_border
        if over {
            bfill = th.accent
        }
        fill_round(bx, by, bw, bh, 6, bfill, 235)
        let blw = measure_text("Copy", csize - 2)
        draw_text("Copy", bx + (bw - blw) / 2, by + (bh - csize + 2) / 2, csize - 2, th.code_ink)
        if over && do_click {
            clipboard_set(seg.text)
        }
        return h
    }
    let lines = wrap_text(seg.text, inner, size)
    var k = 0
    loop {
        if k == lines.len() {
            break
        }
        draw_text(lines[k], x, y + k * line_h, size, th.ink)
        k = k + 1
    }
    return lines.len() * line_h
}






fn msg_height(m: Msg, col_w: int, size: int, line_h: int) -> int {
    let inner = col_w - 32
    if m.role == 0 {
        return wrap_text(m.text, inner, size).len() * line_h + 20
    }
    // assistant: a "Claude" label (28px) then each segment, with a gap between segments.
    let segs = split_segments(m.text)
    var h = 28
    var i = 0
    loop {
        if i == segs.len() {
            break
        }
        if i > 0 {
            h = h + 10
        }
        h = h + seg_height(segs[i], inner, size, line_h)
        i = i + 1
    }
    return h
}






// draw_message renders one turn at (x, y) in a `col_w`-wide column; returns its height. A user turn
// is a right-aligned rounded bubble; Claude's turn is a label, then prose + styled code blocks.
fn draw_message(m: Msg, x: int, y: int, col_w: int, th: Theme, size: int, line_h: int, mono: int,
                mx: int, my: int, do_click: bool) -> int {
    let inner = col_w - 32
    if m.role == 0 {
        // User: a bubble sized to its widest line, hugging the right edge of the column.
        let lines = wrap_text(m.text, inner, size)
        var widest = 0
        var li = 0
        loop {
            if li == lines.len() {
                break
            }
            let lw = measure_text(lines[li], size)
            if lw > widest {
                widest = lw
            }
            li = li + 1
        }
        let bw = widest + 28
        let bh = lines.len() * line_h + 20
        let bx = x + col_w - bw
        fill_round(bx, y, bw, bh, 16, th.bubble, 255)
        var k = 0
        loop {
            if k == lines.len() {
                break
            }
            draw_text(lines[k], bx + 14, y + 10 + k * line_h, size, th.ink)
            k = k + 1
        }
        return bh
    }
    // Claude: a coral label, then prose + code segments flush left.
    fill_circle(x + 9, y + 9, 7, th.accent, 255)
    draw_text("Claude", x + 24, y + 1, size - 2, th.muted)
    let segs = split_segments(m.text)
    var cy = y + 28
    var i = 0
    loop {
        if i == segs.len() {
            break
        }
        if i > 0 {
            cy = cy + 10
        }
        cy = cy + draw_segment(segs[i], x, cy, inner, size, line_h, th, mono, mx, my, do_click)
        i = i + 1
    }
    return cy - y
}






// hit_circle is true when (px,py) is within radius r of centre (cx,cy).
fn hit_circle(px: int, py: int, cx: int, cy: int, r: int) -> bool {
    let dx = px - cx
    let dy = py - cy
    return dx * dx + dy * dy <= r * r
}






// hit_rect is true when (px,py) is inside the rectangle at (x,y) of size w×h.
fn hit_rect(px: int, py: int, x: int, y: int, w: int, h: int) -> bool {
    return px >= x && px < x + w && py >= y && py < y + h
}






// A full colour theme. Two are defined (dark / light); the settings panel swaps between them and
// every surface reads its colours from the active Theme, so re-theming is one assignment.
struct Theme {
    bg: int
    sidebar: int
    panel: int
    bubble: int
    ink: int
    muted: int
    accent: int
    accent_ink: int
    border: int
    field: int
    field_hot: int
    code_bg: int
    code_ink: int
    code_border: int
    send_dim: int
    send_hot: int
    hot: int
}






fn dark_theme() -> Theme {
    return Theme {
        bg: rgb(38, 38, 36), sidebar: rgb(31, 31, 29), panel: rgb(46, 46, 43), bubble: rgb(54, 54, 50),
        ink: rgb(237, 234, 228), muted: rgb(150, 147, 139), accent: rgb(204, 122, 90), accent_ink: rgb(255, 255, 255),
        border: rgb(58, 57, 53), field: rgb(46, 46, 43), field_hot: rgb(56, 56, 52),
        code_bg: rgb(24, 24, 23), code_ink: rgb(214, 202, 173), code_border: rgb(62, 60, 54),
        send_dim: rgb(92, 66, 54), send_hot: rgb(222, 142, 112), hot: rgb(58, 58, 54)
    }
}






fn light_theme() -> Theme {
    return Theme {
        bg: rgb(247, 245, 242), sidebar: rgb(237, 234, 229), panel: rgb(255, 255, 255), bubble: rgb(232, 228, 221),
        ink: rgb(38, 36, 32), muted: rgb(124, 120, 112), accent: rgb(196, 110, 78), accent_ink: rgb(255, 255, 255),
        border: rgb(220, 216, 209), field: rgb(255, 255, 255), field_hot: rgb(244, 242, 238),
        code_bg: rgb(40, 40, 38), code_ink: rgb(224, 214, 190), code_border: rgb(64, 62, 56),
        send_dim: rgb(216, 192, 180), send_hot: rgb(210, 120, 86), hot: rgb(228, 224, 217)
    }
}






// model_name maps the selector index to the API model id; model_label is the human label.
fn model_name(idx: int) -> string {
    if idx == 1 {
        return "claude-sonnet-4-6"
    }
    if idx == 2 {
        return "claude-haiku-4-5-20251001"
    }
    return "claude-opus-4-8"
}






fn model_label(idx: int) -> string {
    if idx == 1 {
        return "Sonnet 4.6"
    }
    if idx == 2 {
        return "Haiku 4.5"
    }
    return "Opus 4.8"
}






// The result of one frame of text editing: the new text, the caret and the selection anchor
// (caret == anchor means no selection), and whether the TEXT changed (so the caller can reset the
// caret blink). Used by BOTH the chat input and the settings field.
struct Edit {
    text: string
    caret: int
    anchor: int
    changed: bool
}






// lo2/hi2 — the ordered ends of a selection (anchor/caret arrive in either order).
fn lo2(a: int, b: int) -> int {
    if a < b {
        return a
    }
    return b
}






fn hi2(a: int, b: int) -> int {
    if a > b {
        return a
    }
    return b
}






// cut_range removes code points [lo, hi) from s (the head + tail rejoined), the selection-delete
// primitive shared by Backspace/Delete/type-over/cut/paste.
fn cut_range(s: string, lo: int, hi: int) -> string {
    return str.cp_slice(s, 0, lo) + str.cp_slice(s, hi, str.cp_count(s))
}






// edit_step applies this frame's keyboard to a (text, caret, anchor): selection-aware ⌘A/⌘C/⌘X/⌘V,
// printable insert (replacing any selection), Backspace/Delete (delete selection else one glyph),
// ←/→/Home/End (shift extends the selection, plain collapses it) — all with auto-repeat. Enter is
// left to the caller. `shift` = a Shift key is held this frame. The ⌘ shortcuts return early since a
// frame that fires one is not also a typing frame.
fn edit_step(text: string, caret: int, anchor: int, cmd: bool, shift: bool) -> Edit {
    var t = text
    var c = caret
    var a = anchor
    var ch = false
    let n0 = str.cp_count(t)

    if cmd && key_pressed(KEY_A) {                        // ⌘A — select all (anchor 0, caret end)
        return Edit { text: t, caret: n0, anchor: 0, changed: false }
    }
    if cmd && key_pressed(KEY_C) {                        // ⌘C — copy the selection to the clipboard
        if a != c {
            clipboard_set(str.cp_slice(t, lo2(a, c), hi2(a, c)))
        }
        return Edit { text: t, caret: c, anchor: a, changed: false }
    }
    if cmd && key_pressed(KEY_X) {                        // ⌘X — cut the selection
        if a != c {
            let lo = lo2(a, c)
            clipboard_set(str.cp_slice(t, lo, hi2(a, c)))
            t = cut_range(t, lo, hi2(a, c))
            c = lo
            a = lo
            ch = true
        }
        return Edit { text: t, caret: c, anchor: a, changed: ch }
    }
    if cmd && key_pressed(KEY_V) {                        // ⌘V — paste, replacing any selection
        let p = clipboard_get()
        if p.len() > 0 {
            if a != c {
                let lo = lo2(a, c)
                t = cut_range(t, lo, hi2(a, c))
                c = lo
            }
            t = str.cp_insert(t, c, p)
            c = c + str.cp_count(p)
            a = c
            ch = true
        }
        return Edit { text: t, caret: c, anchor: a, changed: ch }
    }

    loop {                                                // printable insert — replaces the selection
        let k = char_pressed()
        if k == 0 {
            break
        }
        if k >= 32 {
            if a != c {
                let lo = lo2(a, c)
                t = cut_range(t, lo, hi2(a, c))
                c = lo
            }
            t = str.cp_insert(t, c, from_char_code(k))
            c = c + 1
            a = c
            ch = true
        }
    }
    if key_pressed(KEY_BACKSPACE) || key_repeat(KEY_BACKSPACE) {
        if a != c {
            let lo = lo2(a, c)
            t = cut_range(t, lo, hi2(a, c))
            c = lo
            a = lo
            ch = true
        } else if c > 0 {
            t = str.cp_delete(t, c - 1)
            c = c - 1
            a = c
            ch = true
        }
    }
    if key_pressed(KEY_DELETE) || key_repeat(KEY_DELETE) {
        if a != c {
            let lo = lo2(a, c)
            t = cut_range(t, lo, hi2(a, c))
            c = lo
            a = lo
            ch = true
        } else if c < str.cp_count(t) {
            t = str.cp_delete(t, c)
            ch = true
        }
    }
    if key_pressed(KEY_LEFT) || key_repeat(KEY_LEFT) {
        if !shift && a != c {
            c = lo2(a, c)                                 // collapse to the left edge
        } else if c > 0 {
            c = c - 1
        }
        if !shift {
            a = c
        }
        ch = true
    }
    if key_pressed(KEY_RIGHT) || key_repeat(KEY_RIGHT) {
        if !shift && a != c {
            c = hi2(a, c)                                 // collapse to the right edge
        } else if c < str.cp_count(t) {
            c = c + 1
        }
        if !shift {
            a = c
        }
        ch = true
    }
    if key_pressed(KEY_HOME) {
        c = 0
        if !shift {
            a = c
        }
        ch = true
    }
    if key_pressed(KEY_END) {
        c = str.cp_count(t)
        if !shift {
            a = c
        }
        ch = true
    }
    return Edit { text: t, caret: c, anchor: a, changed: ch }
}






// segmented draws a segmented control (n labels) and returns the selected index — `sel` unless a
// segment was clicked this frame. The chosen segment is filled with the accent.
fn segmented(x: int, y: int, w: int, h: int, labels: [string], sel: int,
             mx: int, my: int, click: bool, size: int, th: Theme) -> int {
    let n = labels.len()
    let segw = w / n
    fill_round(x, y, w, h, 8, th.field, 255)
    var out = sel
    var i = 0
    loop {
        if i == n {
            break
        }
        let sx = x + i * segw
        let over = hit_rect(mx, my, sx, y, segw, h)
        if i == sel {
            fill_round(sx + 2, y + 2, segw - 4, h - 4, 6, th.accent, 255)
        } else if over {
            fill_round(sx + 2, y + 2, segw - 4, h - 4, 6, th.hot, 255)
        }
        var tcol = th.ink
        if i == sel {
            tcol = th.accent_ink
        }
        let lw = measure_text(labels[i], size)
        draw_text(labels[i], sx + (segw - lw) / 2, y + (h - size) / 2, size, tcol)
        if over && click {
            out = i
        }
        i = i + 1
    }
    stroke_round(x, y, w, h, 8, 1, th.border, 160)
    return out
}






// All configurable state, bundled so the settings panel can round-trip it through one function
// (which also keeps main()'s constant pool under the VM's per-function limit).
struct Settings {
    open: bool
    theme_dark: bool
    zoom: int
    model_idx: int
    tok_idx: int
    system: string
    sys_caret: int
    sys_anchor: int
    sys_off: int
    focus: int
}






// draw_settings renders the modal settings panel and handles its widgets, returning the updated
// state. Text editing of the system field happens in main() (it must drain the key queue once);
// here we only handle clicks (selectors, zoom ±, focus, close) and draw.
fn draw_settings(s: Settings, th: Theme, size: int, win_w: int, win_h: int,
                 mx: int, my: int, click: bool, down: bool, was: bool, shift: bool, blink_on: bool) -> Settings {
    var open = s.open
    var theme_dark = s.theme_dark
    var zoom = s.zoom
    var model_idx = s.model_idx
    var tok_idx = s.tok_idx
    var sys_caret = s.sys_caret
    var sys_anchor = s.sys_anchor
    var sys_off = s.sys_off
    var focus = s.focus
    let system = s.system

    fill_round(0, 0, win_w, win_h, 0, rgb(0, 0, 0), 150)   // modal dim
    let pw = 460
    let ph = 490                              // one control row shorter since Temperature was removed
    let px = (win_w - pw) / 2
    let py = (win_h - ph) / 2
    fill_round(px, py, pw, ph, 16, th.panel, 255)
    stroke_round(px, py, pw, ph, 16, 1, th.border, 200)
    draw_text("Settings", px + 24, py + 22, size + 6, th.ink)
    let cxx = px + pw - 42
    let cxy = py + 22
    let cover = hit_rect(mx, my, cxx, cxy, 26, 26)
    var cfill = th.field
    if cover {
        cfill = th.field_hot
    }
    fill_round(cxx, cxy, 26, 26, 7, cfill, 255)
    draw_text("×", cxx + 8, cxy + 2, size, th.muted)
    if cover && click {
        open = false
    }

    let lx = px + 24
    let cw2 = pw - 48
    let ctlh = 36
    var ry = py + 74

    draw_text("Appearance", lx, ry, size - 4, th.muted)
    var th_sel = 1
    if theme_dark {
        th_sel = 0
    }
    let new_th = segmented(lx, ry + 22, cw2, ctlh, ["Dark", "Light"], th_sel, mx, my, click, size - 2, th)
    theme_dark = new_th == 0
    ry = ry + 70

    draw_text("Model", lx, ry, size - 4, th.muted)
    model_idx = segmented(lx, ry + 22, cw2, ctlh, ["Opus 4.8", "Sonnet 4.6", "Haiku 4.5"], model_idx, mx, my, click, size - 5, th)
    ry = ry + 70

    draw_text("Max tokens", lx, ry, size - 4, th.muted)
    tok_idx = segmented(lx, ry + 22, cw2, ctlh, ["1K", "2K", "4K", "8K"], tok_idx, mx, my, click, size - 2, th)
    ry = ry + 70

    draw_text("Zoom", lx, ry, size - 4, th.muted)
    let zbtn = 40
    let zby = ry + 22
    let mz_over = hit_rect(mx, my, lx, zby, zbtn, ctlh)
    var mzf = th.field
    if mz_over {
        mzf = th.field_hot
    }
    fill_round(lx, zby, zbtn, ctlh, 8, mzf, 255)
    stroke_round(lx, zby, zbtn, ctlh, 8, 1, th.border, 150)
    draw_text("-", lx + zbtn / 2 - 4, zby + (ctlh - size) / 2, size, th.ink)
    if mz_over && click {
        zoom = zoom - 10
        if zoom < 60 {
            zoom = 60
        }
    }
    let pzx = lx + cw2 - zbtn
    let pz_over = hit_rect(mx, my, pzx, zby, zbtn, ctlh)
    var pzf = th.field
    if pz_over {
        pzf = th.field_hot
    }
    fill_round(pzx, zby, zbtn, ctlh, 8, pzf, 255)
    stroke_round(pzx, zby, zbtn, ctlh, 8, 1, th.border, 150)
    draw_text("+", pzx + zbtn / 2 - 5, zby + (ctlh - size) / 2, size, th.ink)
    if pz_over && click {
        zoom = zoom + 10
        if zoom > 220 {
            zoom = 220
        }
    }
    let zlab = "{zoom}%"
    let zlw = measure_text(zlab, size)
    draw_text(zlab, lx + (cw2 - zlw) / 2, zby + (ctlh - size) / 2, size, th.ink)
    ry = ry + 70

    draw_text("System prompt", lx, ry, size - 4, th.muted)
    let sf_y = ry + 22
    let stx = lx + 12
    let stw = cw2 - 24
    let sf_over = hit_rect(mx, my, lx, sf_y, cw2, ctlh)
    var sff = th.field
    if sf_over {
        sff = th.field_hot
    }
    fill_round(lx, sf_y, cw2, ctlh, 8, sff, 255)
    if click {
        if sf_over {
            focus = 1
            sys_caret = caret_from_x(system, mx - stx + sys_off, size)
            if !shift {
                sys_anchor = sys_caret                 // plain click collapses; shift-click extends
            }
        } else {
            focus = 0
        }
    } else if focus == 1 && down && was {
        sys_caret = caret_from_x(system, mx - stx + sys_off, size)   // drag extends selection
    }
    if focus == 1 {
        stroke_round(lx, sf_y, cw2, ctlh, 8, 2, th.accent, 255)
    } else {
        stroke_round(lx, sf_y, cw2, ctlh, 8, 1, th.border, 150)
    }
    let slh = text_line_height(size)             // true line box, so the highlight/caret centre on the glyphs
    let sty = sf_y + (ctlh - slh) / 2
    let scpx = measure_text(str.cp_prefix(system, sys_caret), size)
    if scpx - sys_off > stw {
        sys_off = scpx - stw
    }
    if scpx - sys_off < 0 {
        sys_off = scpx
    }
    if sys_off < 0 {
        sys_off = 0
    }
    clip_push(stx, sf_y, stw, ctlh)
    if focus == 1 && sys_anchor != sys_caret {         // translucent accent highlight under the selection
        let xlo = measure_text(str.cp_prefix(system, lo2(sys_anchor, sys_caret)), size)
        let xhi = measure_text(str.cp_prefix(system, hi2(sys_anchor, sys_caret)), size)
        fill_round(stx + xlo - sys_off, sty, xhi - xlo, slh, 0, th.accent, 70)
    }
    if system.len() == 0 && focus != 1 {
        draw_text("Optional — steer Claude's behaviour", stx, sty, size, th.muted)
    } else {
        draw_text(system, stx - sys_off, sty, size, th.ink)
    }
    if focus == 1 && blink_on {
        draw_rect(stx + scpx - sys_off, sty, 2, slh, th.accent)
    }
    clip_pop()

    if click && !hit_rect(mx, my, px, py, pw, ph) {   // click the backdrop to close
        open = false
    }
    return Settings {
        open: open, theme_dark: theme_dark, zoom: zoom, model_idx: model_idx, tok_idx: tok_idx,
        system: system, sys_caret: sys_caret, sys_anchor: sys_anchor, sys_off: sys_off, focus: focus
    }
}






fn main() -> int {
    let api_key = env("ANTHROPIC_API_KEY")
    window_open(1100, 760, "Claude")      // resizable; geometry tracks the live window size

    // Diagnostics: set EMBER_TAPE=/path to record one JSON line per frame, flushed for `tail -f`.
    let tape_path = env("EMBER_TAPE")
    if tape_path.len() > 0 {
        tape_open(tape_path)
    }

    // Showcase fonts, loaded from disk at runtime (font 0 = embedded Inter; both fall back to it).
    var serif = 0
    let f_serif = load_font("/System/Library/Fonts/NewYork.ttf")
    if f_serif >= 0 {
        serif = f_serif
    }
    var mono = 0
    let f_mono = load_font("/System/Library/Fonts/SFNSMono.ttf")
    if f_mono >= 0 {
        mono = f_mono
    }

    // --- conversation + input state ---
    var convo: [Msg] = []
    var input = ""
    var caret = 0                         // caret position in code points
    var sel_anchor = 0                    // selection anchor (== caret ⇒ no selection)
    var scroll = 0
    var pending = false
    var was_down = false
    var prev_open = false                  // last frame's settings state (drives the open/close tape marks)
    var frame = 0                         // frame counter (drives the caret blink)
    var last_edit = 0                     // frame of the last edit
    var text_off = 0                      // input text horizontal scroll
    let ready = api_key.len() > 0

    // --- configurable settings (all wired to behaviour) ---
    var theme_dark = true                 // dark / light
    var zoom = 100                        // text zoom %, 60..220 (⌘+/⌘-/⌘-wheel)
    var settings_open = false
    var model_idx = 0                     // 0 Opus · 1 Sonnet · 2 Haiku  → the API model
    var tok_idx = 1                       // max_tokens preset: 1K/2K/4K/8K
    var system = ""                       // system prompt, sent to the API
    var sys_caret = 0
    var sys_anchor = 0                     // settings-field selection anchor
    var sys_off = 0
    var focus = 0                         // 0 = chat input, 1 = settings system field

    // --- async transport: spawn the fetch worker and run the whole render loop inside its nursery.
    // The loop dispatches a request body on `req_ch` and polls `resp_ch` with the non-blocking
    // try_recv, so the blocking HTTPS call happens on the worker's OS thread while raylib keeps
    // drawing on the main thread. The nursery spans the loop; closing `req_ch` after it joins the
    // worker. (The loop body keeps its original indentation — it simply now lives one scope deeper.)
    let req_ch: Channel<string> = channel(2)
    let resp_ch: Channel<string> = channel(2)
    nursery {
    spawn fetch_worker(api_key, req_ch, resp_ch)
    loop {
        if window_should_close() {
            break
        }

        // ---- this frame's raw input ----
        let win_w = screen_width()           // responsive: track the live (resizable) window
        let win_h = screen_height()
        let mx = mouse_x()
        let my = mouse_y()
        let down = mouse_down()
        let click = down && !was_down
        let wheel = mouse_wheel()
        let cmd = key_down(KEY_SUPER_L) || key_down(KEY_SUPER_R) || key_down(KEY_CTRL_L)
        let shift = key_down(KEY_SHIFT_L) || key_down(KEY_SHIFT_R)
        frame = frame + 1
        var just_opened = false            // settings opened THIS frame → don't let the same click close it

        // ---- global shortcuts ----
        if cmd && key_pressed(KEY_N) && !pending {
            convo = []
            input = ""
            caret = 0
            sel_anchor = 0
            scroll = 0
        }
        if cmd && key_pressed(KEY_COMMA) {
            settings_open = !settings_open
            if settings_open {
                just_opened = true
            }
        }
        if key_pressed(KEY_ESCAPE) && settings_open {
            settings_open = false
        }
        if cmd && key_pressed(KEY_EQUAL) {
            zoom = zoom + 10
        }
        if cmd && key_pressed(KEY_MINUS) {
            zoom = zoom - 10
        }
        if cmd && wheel != 0 {
            zoom = zoom + wheel * 10
        }
        if zoom > 220 {
            zoom = 220
        }
        if zoom < 60 {
            zoom = 60
        }

        // ---- sizes derived from zoom; active theme ----
        let size = 20 * zoom / 100
        let line_h = size * 27 / 20
        let input_h = size * 2 + 18
        var th = dark_theme()
        if !theme_dark {
            th = light_theme()
        }

        // ---- geometry (live window + zoomed column) ----
        let side_w = 264
        let main_x = side_w
        let main_w = win_w - side_w
        var col_w = 680 * zoom / 100
        let maxw = main_w - 64
        if col_w > maxw {
            col_w = maxw
        }
        if col_w < 320 {
            col_w = 320
        }
        let col_x = main_x + (main_w - col_w) / 2
        let conv_top = 24
        let conv_bot = win_h - input_h - 36
        let view_h = conv_bot - conv_top
        let in_x = col_x
        let in_y = win_h - input_h - 18
        let send_r = input_h / 2 - 9
        let send_cx = in_x + col_w - send_r - 12
        let send_cy = in_y + input_h / 2
        let text_x = in_x + 18
        let text_w = col_w - 36 - input_h
        let over_input = !settings_open && hit_rect(mx, my, in_x, in_y, col_w - input_h, input_h)
        let nc_x = 16
        let nc_y = 64
        let nc_w = side_w - 32
        let nc_h = 40
        let gear_x = 20
        let gear_y = win_h - 42
        let gear_w = side_w - 40
        let gear_h = 30

        // ---- measure conversation height + clamp scroll ----
        var total = 0
        var mi = 0
        loop {
            if mi == convo.len() {
                break
            }
            total = total + msg_height(convo[mi], col_w, size, line_h) + 24
            mi = mi + 1
        }
        if pending {
            total = total + 40
        }
        var max_scroll = total - view_h
        if max_scroll < 0 {
            max_scroll = 0
        }
        if !cmd && !settings_open {
            scroll = scroll - wheel * 60
        }
        if scroll > max_scroll {
            scroll = max_scroll
        }
        if scroll < 0 {
            scroll = 0
        }

        // ---- chat interaction (suppressed while settings is open) ----
        if !settings_open {
            focus = 0
            if click && hit_rect(mx, my, gear_x, gear_y, gear_w, gear_h) {
                settings_open = true
                just_opened = true          // consume this click so the panel doesn't close instantly
            }
            if click && hit_rect(mx, my, nc_x, nc_y, nc_w, nc_h) && !pending {
                tape_mark("new_chat", "clear")
                convo = []
                input = ""
                caret = 0
                sel_anchor = 0
                scroll = 0
            }
            if click && over_input {
                caret = caret_from_x(input, mx - text_x + text_off, size)
                if !shift {
                    sel_anchor = caret              // plain click collapses; shift-click extends
                }
                last_edit = frame
            } else if over_input && down && was_down {
                caret = caret_from_x(input, mx - text_x + text_off, size)   // drag extends selection
                last_edit = frame
            }
            let e = edit_step(input, caret, sel_anchor, cmd, shift)
            if e.changed || e.caret != caret {
                last_edit = frame
            }
            input = e.text
            caret = e.caret
            sel_anchor = e.anchor
            let over_send = hit_circle(mx, my, send_cx, send_cy, send_r + 6)
            var submit = false
            if key_pressed(KEY_ENTER) {
                submit = true
            }
            if click && over_send {
                submit = true
            }
            if submit && input.len() > 0 && !pending {
                tape_mark("submit", "send")
                convo.append(Msg { role: 0, text: input })
                // Dispatch the request to the worker fiber and keep rendering. `req_ch` has room
                // (only one request is ever in flight — `pending` gates a second submit), so this
                // send never blocks the render thread. The reply arrives later via try_recv below.
                if ready {
                    let body = build_request(model_name(model_idx), max_tokens_for(tok_idx), system, convo)
                    send(req_ch, body)
                }
                input = ""
                caret = 0
                sel_anchor = 0
                pending = true
                scroll = 1000000
            }
        } else {
            if focus == 1 {
                let e = edit_step(system, sys_caret, sys_anchor, cmd, shift)
                if e.changed || e.caret != sys_caret {
                    last_edit = frame
                }
                system = e.text
                sys_caret = e.caret
                sys_anchor = e.anchor
            }
        }

        // ============================ render ============================
        frame_begin(th.bg)

        // ---- sidebar ----
        fill_round(0, 0, side_w, win_h, 0, th.sidebar, 255)
        draw_rect(side_w - 1, 0, 1, win_h, th.border)
        fill_circle(26, 30, 9, th.accent, 255)
        set_font(serif)
        draw_text("Claude", 44, 16, size + 8, th.ink)
        set_font(0)
        var nc_fill = th.field
        if !settings_open && hit_rect(mx, my, nc_x, nc_y, nc_w, nc_h) {
            nc_fill = th.hot
        }
        fill_round(nc_x, nc_y, nc_w, nc_h, 10, nc_fill, 255)
        stroke_round(nc_x, nc_y, nc_w, nc_h, 10, 1, th.border, 160)
        draw_text("+  New chat", 32, nc_y + (nc_h - size) / 2, size, th.ink)
        draw_text("Recents", 24, 128, size - 4, th.muted)
        var gear_fill = th.sidebar
        if !settings_open && hit_rect(mx, my, gear_x, gear_y, gear_w, gear_h) {
            gear_fill = th.hot
        }
        fill_round(gear_x, gear_y, gear_w, gear_h, 8, gear_fill, 255)
        draw_text("Settings · {model_label(model_idx)}", gear_x + 12, gear_y + (gear_h - size + 4) / 2, size - 4, th.muted)

        // ---- conversation ----
        let conv_click = click && !settings_open && my >= conv_top && my < conv_bot
        clip_push(main_x, conv_top, main_w, view_h)
        if convo.len() == 0 {
            set_font(serif)
            draw_text("How can I help you today?", col_x, conv_top + 34, size + 12, th.ink)
            set_font(0)
            let starters = ["Explain a tricky concept simply", "Write and explain some code",
                            "Brainstorm ideas with me", "Draft a difficult email"]
            var sy = conv_top + 34 + size + 30
            var si = 0
            loop {
                if si == starters.len() {
                    break
                }
                let sh = size + 22
                let sover = hit_rect(mx, my, col_x, sy, col_w, sh)
                var sf = th.field
                if sover {
                    sf = th.field_hot
                }
                fill_round(col_x, sy, col_w, sh, 10, sf, 255)
                stroke_round(col_x, sy, col_w, sh, 10, 1, th.border, 140)
                draw_text(starters[si], col_x + 16, sy + (sh - size) / 2, size, th.ink)
                if sover && conv_click {
                    input = starters[si]
                    caret = str.cp_count(input)
                    last_edit = frame
                }
                sy = sy + sh + 10
                si = si + 1
            }
        }
        var y = conv_top - scroll
        var di = 0
        loop {
            if di == convo.len() {
                break
            }
            let h = draw_message(convo[di], col_x, y, col_w, th, size, line_h, mono, mx, my, conv_click)
            y = y + h + 24
            di = di + 1
        }
        if pending {
            // Animated indicator — visible proof the window is LIVE while the worker fetches
            // (the old synchronous call froze the whole UI here). Integer-only, and cycling between
            // constant literals rather than interpolating (OFI-059: interpolation leaks per frame).
            let ph = frame % 60
            var pul = ph
            if ph > 30 {
                pul = 60 - ph
            }
            fill_circle(col_x + 9, y + 9, 5 + pul / 8, th.accent, 255)
            var label = "Claude is thinking"
            let dots = (frame / 18) % 4
            if dots == 1 {
                label = "Claude is thinking ."
            }
            if dots == 2 {
                label = "Claude is thinking . ."
            }
            if dots == 3 {
                label = "Claude is thinking . . ."
            }
            draw_text(label, col_x + 24, y + 1, size, th.muted)
        }
        clip_pop()

        // ---- scroll-to-bottom button ----
        if max_scroll - scroll > 40 {
            let jb_cx = main_x + main_w - 42
            let jb_cy = conv_bot - 26
            let jover = hit_circle(mx, my, jb_cx, jb_cy, 18)
            var jf = th.field
            if jover {
                jf = th.field_hot
            }
            fill_circle(jb_cx, jb_cy, 18, jf, 255)
            stroke_round(jb_cx - 18, jb_cy - 18, 36, 36, 18, 1, th.border, 160)
            draw_text("v", jb_cx - 4, jb_cy - 10, size - 4, th.ink)
            if jover && click && !settings_open {
                scroll = max_scroll
            }
        }

        // ---- input bar ----
        var in_fill = th.field
        if over_input {
            in_fill = th.field_hot
        }
        fill_round(in_x, in_y, col_w, input_h, 16, in_fill, 255)
        var ring_a = 80
        if over_input {
            ring_a = 150
        }
        stroke_round(in_x, in_y, col_w, input_h, 16, 2, th.accent, ring_a)
        let ilh = text_line_height(size)             // true line box, so the highlight/caret centre on the glyphs
        let ty = in_y + (input_h - ilh) / 2
        let caret_px = measure_text(str.cp_prefix(input, caret), size)
        if caret_px - text_off > text_w {
            text_off = caret_px - text_w
        }
        if caret_px - text_off < 0 {
            text_off = caret_px
        }
        if text_off < 0 {
            text_off = 0
        }
        clip_push(text_x, in_y, text_w, input_h)
        if !settings_open && sel_anchor != caret {       // translucent accent highlight under the selection
            let xlo = measure_text(str.cp_prefix(input, lo2(sel_anchor, caret)), size)
            let xhi = measure_text(str.cp_prefix(input, hi2(sel_anchor, caret)), size)
            fill_round(text_x + xlo - text_off, ty, xhi - xlo, ilh, 0, th.accent, 70)
        }
        if input.len() == 0 {
            draw_text("Reply to Claude…", text_x, ty, size, th.muted)
        } else {
            draw_text(input, text_x - text_off, ty, size, th.ink)
        }
        let blink_on = (frame - last_edit) < 30 || (frame / 30) % 2 == 0
        if !settings_open && blink_on {
            draw_rect(text_x + caret_px - text_off, ty, 2, ilh, th.accent)
        }
        clip_pop()
        var send_col = th.accent
        if input.len() == 0 {
            send_col = th.send_dim
        } else if !settings_open && hit_circle(mx, my, send_cx, send_cy, send_r + 6) {
            send_col = th.send_hot
        }
        fill_circle(send_cx, send_cy, send_r, send_col, 255)
        draw_text("↑", send_cx - 6, send_cy - size / 2 - 2, size, th.accent_ink)
        if input.len() > 0 {
            draw_text("{str.cp_count(input)}", in_x + 8, in_y - size, size - 6, th.muted)
        }

        // ============================ settings overlay ============================
        if settings_open {
            let s = draw_settings(Settings {
                open: settings_open, theme_dark: theme_dark, zoom: zoom, model_idx: model_idx,
                tok_idx: tok_idx, system: system, sys_caret: sys_caret, sys_anchor: sys_anchor,
                sys_off: sys_off, focus: focus
            }, th, size, win_w, win_h, mx, my, click && !just_opened, down, was_down, shift, blink_on)
            settings_open = s.open
            theme_dark = s.theme_dark
            zoom = s.zoom
            model_idx = s.model_idx
            tok_idx = s.tok_idx
            sys_caret = s.sys_caret
            sys_anchor = s.sys_anchor
            sys_off = s.sys_off
            focus = s.focus
        }

        // record settings open/close transitions on the UI tape (visible under `tail -f`)
        if settings_open != prev_open {
            if settings_open {
                tape_mark("settings", "open")
            } else {
                tape_mark("settings", "close")
            }
            prev_open = settings_open
        }

        frame_end()
        was_down = down

        // ---- poll the worker for the reply (non-blocking: the GUI keeps rendering "thinking…") ----
        if pending {
            if ready {
                match try_recv(resp_ch) {
                    case Some(reply) {
                        convo.append(Msg { role: 1, text: reply })
                        pending = false
                        scroll = 1000000
                    }
                    case None {
                    }
                }
            } else {
                convo.append(Msg { role: 1, text: "I can't reach the API yet — set ANTHROPIC_API_KEY in your shell and relaunch, then I'll reply for real." })
                pending = false
                scroll = 1000000
            }
        }
    }
    close(req_ch)        // wake the worker out of recv → it returns None and exits
    }                    // nursery: joins the fetch worker here

    window_close()
    return 0
}
