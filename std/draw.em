// std/draw — immediate-mode drawing over Ember's native graphics backend (MANIFESTO
// §5g). The UI is a pure function of state, drawn fresh every frame: there is no
// retained widget tree, so app state is just your own Ember values and ownership
// stays clean. Colors are packed 0xRRGGBB ints; key codes follow the backend.
//
//   import "std/draw" as draw
//   draw.window(800, 600, "hello")
//   loop {
//       if draw.closing() { break }
//       draw.begin(draw.DARKGRAY)
//       draw.rect(x, y, 50, 50, draw.RED)
//       draw.finish()
//   }
//   draw.close()


// ---- colors (packed 0xRRGGBB) ----

let BLACK    = 0           // 0x000000
let WHITE    = 16777215    // 0xFFFFFF
let DARKGRAY = 2105376     // 0x202020
let RED      = 16711680    // 0xFF0000
let GREEN    = 65280       // 0x00FF00
let BLUE     = 255         // 0x0000FF
let YELLOW   = 16776960    // 0xFFFF00


// rgb packs three 0..255 channels into a single color int.
fn rgb(r: int, g: int, b: int) -> int {
    return r * 65536 + g * 256 + b
}


// ---- key codes (raylib) ----

let RIGHT = 262
let LEFT  = 263
let DOWN  = 264
let UP    = 265
let SPACE = 32
let ENTER = 257
let ESCAPE = 256


// ---- window + frame ----

// window opens the application window; call once before the loop.
fn window(width: int, height: int, title: string) {
    window_open(width, height, title)
}


// closing reports that the user asked to close the window (or pressed Esc).
fn closing() -> bool {
    return window_should_close()
}


// close tears the window down; call once after the loop.
fn close() {
    window_close()
}


// begin starts a frame and clears it to `bg`. Pair with `finish`.
fn begin(bg: int) {
    frame_begin(bg)
}


// finish presents the frame and pumps OS events.
fn finish() {
    frame_end()
}


// ---- drawing ----

// rect draws a filled rectangle at (x, y) of size w by h in `color`.
fn rect(x: int, y: int, w: int, h: int, color: int) {
    draw_rect(x, y, w, h, color)
}


// text draws `s` at (x, y) with the given pixel size and color.
fn text(s: string, x: int, y: int, size: int, color: int) {
    draw_text(s, x, y, size, color)
}


// ---- rich shapes (the modern look: rounding, translucency, gradients, soft shadows) ----
// `alpha` is 0..255; `radius` is a corner radius in pixels (0 = square). These compose: a
// widget is a shadow, then a rounded (often gradient) fill, then a thin rounded border.

// round draws a filled rounded rectangle.
fn round(x: int, y: int, w: int, h: int, radius: int, color: int, alpha: int) {
    fill_round(x, y, w, h, radius, color, alpha)
}


// stroke draws a rounded rectangle outline `thick` pixels wide (a border / focus ring).
fn stroke(x: int, y: int, w: int, h: int, radius: int, thick: int, color: int, alpha: int) {
    stroke_round(x, y, w, h, radius, thick, color, alpha)
}


// gradient draws a rounded rectangle shaded vertically from `top` to `bottom` (subtle depth).
fn gradient(x: int, y: int, w: int, h: int, radius: int, top: int, bottom: int, alpha: int) {
    fill_grad(x, y, w, h, radius, top, bottom, alpha)
}


// drop_shadow casts a soft shadow sized to a widget at (x, y, w, h) — draw it BEFORE the widget.
fn drop_shadow(x: int, y: int, w: int, h: int, radius: int, alpha: int) {
    shadow(x, y, w, h, radius, alpha)
}


// circle draws a filled circle centred at (cx, cy) — toggle knobs, radio dots, slider handles.
fn circle(cx: int, cy: int, r: int, color: int, alpha: int) {
    fill_circle(cx, cy, r, color, alpha)
}


// ---- input (polled — events are values, not callbacks) ----

// key reports whether the key with the given code is currently held.
fn key(code: int) -> bool {
    return key_down(code)
}


// wheel returns this frame's scroll-wheel movement in notches (+ up, - down, 0 if none).
fn wheel() -> int {
    return mouse_wheel()
}


// ---- UI tape (MANIFESTO §5c) ----

// tape_on starts recording a UI tape to `path`: one JSON line per frame (the input
// and every draw command) plus std/ui interaction events (click/toggle/focus/menu).
// Returns true on success. It's the same JSON-lines shape as the instruction tape, so
// an LLM can read what the UI did and why. Call tape_off to stop.
fn tape_on(path: string) -> bool {
    return tape_open(path) == 1
}


// tape_off stops recording and flushes the tape file.
fn tape_off() {
    tape_close()
}
