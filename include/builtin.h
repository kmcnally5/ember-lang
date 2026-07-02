#ifndef EMBER_BUILTIN_H
#define EMBER_BUILTIN_H

// Built-in (native) functions: implemented in C, callable from Ember. Each has a
// stable native id that the checker/codegen reference by name and the VM
// dispatches on. This registry is the seed of the standard library.
enum {
    NATIVE_PRINT      = 0,   // print(x)             — writes x, no trailing newline
    NATIVE_PRINTLN    = 1,   // println(x)           — writes x then a newline
    NATIVE_READ_LINE  = 2,   // read_line() -> string — one stdin line (no '\n');
                             //                         empty string at end of input
    NATIVE_READ_FILE  = 3,   // read_file(path) -> string — whole file; empty on error
    NATIVE_WRITE_FILE = 4,    // write_file(path, text)    — write text to a file
    // The irreducible string + math primitives the Ember stdlib builds on.
    NATIVE_CHAR_CODE     = 5, // char_code(s) -> int       — byte value of s[0] (−1 if empty)
    NATIVE_FROM_CHAR_CODE= 6, // from_char_code(n) -> string — one-byte string of value n
    NATIVE_PARSE_FLOAT   = 7, // parse_float(s) -> float    — 0.0 if not a number
    NATIVE_SQRT          = 8, // sqrt(x) -> float
    NATIVE_POW           = 9, // pow(b, e) -> float
    NATIVE_ABS           = 10,// abs(x) -> float            — |x|
    NATIVE_FLOOR         = 11,// floor(x) -> float
    NATIVE_CEIL          = 12,// ceil(x) -> float
    NATIVE_ROUND         = 13,// round(x) -> float          — to nearest, halves away from 0
    NATIVE_RANDOM        = 14,// random() -> float          — in [0, 1)
    NATIVE_HASH          = 15,// hash(s) -> int             — non-negative hash of a string
    NATIVE_CONCAT        = 16,// concat(parts) -> string    — join a [string] in one pass
    // Program environment: how an Ember program talks to the world it was launched in.
    NATIVE_ARGS          = 17,// args() -> [string]         — command-line arguments (after the file)
    NATIVE_ENV           = 18,// env(name) -> string        — environment variable ("" if unset)
    NATIVE_EXIT          = 19,// exit(code)                 — terminate the program with an exit code
    // Witness shims for built-in key types satisfying Hash/Eq (Map<K,V>). Not callable
    // by name from Ember; referenced only from a witness vtable and dispatched by the
    // indirect-call opcodes when the type parameter is bound to a scalar/string.
    NATIVE_HASH_ANY      = 20,// hash(self) for a built-in key — hash any scalar/string Value
    NATIVE_VALUE_EQ      = 21,// eq(self, other) for a built-in key — structural value equality

    NATIVE_BYTE_SLICE    = 22,// byte_slice(s, start, end) -> string — the raw bytes [start,end) of
                              // s, BYTE-indexed (not code-point); the faithful inverse of .bytes()
                              // over a sub-range. Added for the self-hosted lexer (exact lexemes).

    NATIVE_FROM_BYTES    = 23 // from_bytes(bytes) -> string — a string whose raw buffer is EXACTLY the
                              // [u8] array's bytes; the inverse of .bytes() with NO UTF-8 re-encoding
                              // (unlike from_char_code), so it can build ANY byte sequence. The Ember-
                              // side binary-serializer primitive (docs/design/bytecode-container.md).
};

// A witness method slot normally holds an Ember function-table index. For a built-in
// type satisfying Hash/Eq there is no Ember function, so the slot holds a NATIVE id
// offset by this base; the indirect-call opcodes detect the range and call the native.
#define WITNESS_NATIVE_BASE 1000000

// Graphics is an opt-in build (MANIFESTO §5g): `-DEMBER_GRAPHICS=1` links the raylib
// backend and registers these native primitives. The default build defines it to 0,
// so the compiler stays dependency-free and the test suite needs no display. Ember
// only *describes* each frame through these; the std/draw + std/ui modules wrap them.
#ifndef EMBER_GRAPHICS
#define EMBER_GRAPHICS 0
#endif
// The graphics native-call ids are known to the COMPILER unconditionally — pure type data, no
// raylib — so the type checker (and thus the language server) validates calls to them in any build.
// Only the IMPLEMENTATION (the raylib backend + the VM / native-backend dispatch) is gated on
// EMBER_GRAPHICS; a default build type-checks a graphics program but cannot run it.
enum {
    NATIVE_GFX_WINDOW_OPEN   = 100, // window_open(w, h, title)
    NATIVE_GFX_WINDOW_CLOSE  = 101, // window_close()
    NATIVE_GFX_SHOULD_CLOSE  = 102, // window_should_close() -> bool
    NATIVE_GFX_FRAME_BEGIN   = 103, // frame_begin(bg_color)   — start a frame, clear
    NATIVE_GFX_FRAME_END     = 104, // frame_end()             — present the frame
    NATIVE_GFX_DRAW_RECT     = 105, // draw_rect(x, y, w, h, color)
    NATIVE_GFX_DRAW_TEXT     = 106, // draw_text(text, x, y, size, color)
    NATIVE_GFX_KEY_DOWN      = 107, // key_down(keycode) -> bool
    NATIVE_GFX_MOUSE_X       = 108, // mouse_x() -> int
    NATIVE_GFX_MOUSE_Y       = 109, // mouse_y() -> int
    NATIVE_GFX_MOUSE_DOWN    = 110, // mouse_down() -> bool   (left button held)
    NATIVE_GFX_MEASURE_TEXT  = 111, // measure_text(text, size) -> int  (pixel width)
    NATIVE_GFX_CHAR_PRESSED  = 112, // char_pressed() -> int  (next typed char, 0 if none)
    NATIVE_GFX_KEY_PRESSED   = 113, // key_pressed(keycode) -> bool  (edge: pressed this frame)
    NATIVE_GFX_SET_LAYER     = 114, // set_layer(z)  — z-order for the draws that follow
    NATIVE_GFX_CLIP_PUSH     = 115, // clip_push(x, y, w, h) — mask following draws to a rect
    NATIVE_GFX_CLIP_POP      = 116, // clip_pop()    — end the most recent clip region
    NATIVE_GFX_TAPE_OPEN     = 117, // tape_open(path) -> int — start the UI tape
    NATIVE_GFX_TAPE_CLOSE    = 118, // tape_close()  — stop + flush the UI tape
    NATIVE_GFX_TAPE_MARK     = 119, // tape_mark(kind, label) — record an interaction
    // Rich primitives for the modern look (rounded, translucent, gradient, shadow, round).
    NATIVE_GFX_FILL_ROUND    = 120, // fill_round(x,y,w,h,radius,color,alpha)
    NATIVE_GFX_STROKE_ROUND  = 121, // stroke_round(x,y,w,h,radius,thickness,color,alpha)
    NATIVE_GFX_FILL_GRAD     = 122, // fill_grad(x,y,w,h,radius,top,bottom,alpha) — vertical
    NATIVE_GFX_SHADOW        = 123, // shadow(x,y,w,h,radius,alpha) — soft drop shadow
    NATIVE_GFX_FILL_CIRCLE   = 124, // fill_circle(cx,cy,r,color,alpha)
    NATIVE_GFX_MOUSE_WHEEL   = 125, // mouse_wheel() -> int  (notches this frame; +up / -down)
    NATIVE_GFX_KEY_REPEAT    = 126, // key_repeat(keycode) -> bool  (auto-repeat fired this frame)
    NATIVE_GFX_LOAD_FONT     = 127, // load_font(path) -> int  (font slot id, or -1 on failure)
    NATIVE_GFX_SET_FONT      = 128, // set_font(id)  — font slot for the text that follows
    NATIVE_GFX_CLIPBOARD_SET = 129, // clipboard_set(text)  — copy text to the system clipboard
    NATIVE_GFX_CLIPBOARD_GET = 130, // clipboard_get() -> string  — paste from the system clipboard
    NATIVE_GFX_SCREEN_W      = 131, // screen_width() -> int   — current window width (resizable)
    NATIVE_GFX_SCREEN_H      = 132, // screen_height() -> int  — current window height
    NATIVE_GFX_TEXT_LINE_H   = 133, // text_line_height(size) -> int — font line height (px) at size
    NATIVE_GFX_SET_CURSOR    = 134, // set_cursor(shape) — OS pointer for the frame (tape-silent; reset each frame_begin)
    NATIVE_GFX_FRAME_CAPTURE = 135, // frame_capture(path) -> int — queue a PNG screenshot of this frame
    NATIVE_GFX_SET_EVENT_WAIT= 136, // set_event_waiting(on) — when on, EndDrawing blocks on OS events (idle CPU ~0)
    NATIVE_GFX_HAD_INPUT     = 137, // had_input() -> bool — any mouse move/button/wheel/resize this frame
    NATIVE_GFX_MEASURE_MISSES= 138, // measure_misses() -> int — measure_text cache misses since this frame_begin
    NATIVE_GFX_FRAME_STEPS   = 139, // frame_steps() -> int — physics sub-steps for last frame's elapsed time
    NATIVE_GFX_SET_ALPHA     = 140, // set_alpha(a) — fade multiplier 0..255 for the following draws
    NATIVE_GFX_MOUSE_RDOWN   = 141, // mouse_right_down() -> bool  (right button held — right-click context menus)
    NATIVE_GFX_DROPPED_FILES = 142  // dropped_files() -> string   (newline-joined paths dropped this frame, "" if none)
};

// Returns the native id for a built-in function name, or -1 if `name` is not a
// built-in. Used by the checker (to recognise the call) and codegen (to emit it).
int native_id_for_name(const char *name);

#endif // EMBER_BUILTIN_H
