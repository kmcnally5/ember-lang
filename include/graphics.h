#ifndef EMBER_GRAPHICS_H
#define EMBER_GRAPHICS_H

// The native graphics bridge (MANIFESTO §5g). These thin C functions are the ONLY
// place the backend (raylib) is touched — vm.c calls them, never raylib directly —
// so the dependency is isolated to src/graphics.c and the engine stays swappable.
// Colors are packed 0xRRGGBB ints (alpha is always opaque). Graphics is opt-in:
// in the default build EMBER_GRAPHICS is 0 and none of this is declared or linked.
#ifndef EMBER_GRAPHICS
#define EMBER_GRAPHICS 0
#endif

#if EMBER_GRAPHICS
void ember_gfx_window_open(int width, int height, const char *title);
void ember_gfx_window_close(void);
int  ember_gfx_should_close(void);            // 1 when the user asked to close
void ember_gfx_frame_begin(int bg_color);     // start a frame, clear to bg_color
void ember_gfx_frame_end(void);               // present the frame, pump OS events
void ember_gfx_draw_rect(int x, int y, int w, int h, int color);
void ember_gfx_draw_text(const char *text, int x, int y, int size, int color);
int  ember_gfx_key_down(int keycode);          // 1 while the key is held
int  ember_gfx_mouse_x(void);
int  ember_gfx_mouse_y(void);
int  ember_gfx_mouse_down(void);               // 1 while the left button is held
int  ember_gfx_measure_text(const char *text, int size);  // pixel width
int  ember_gfx_text_line_height(int size);                // font line height in px at logical size
int  ember_gfx_char_pressed(void);             // next typed char this frame, 0 if none
int  ember_gfx_key_pressed(int keycode);       // 1 only on the frame the key goes down
int  ember_gfx_key_repeat(int keycode);        // 1 on each auto-repeat tick while held
int  ember_gfx_load_font(const char *path);    // load a font from disk -> slot id, or -1
void ember_gfx_set_font(int id);               // select the font slot for following text
void ember_gfx_set_cursor(int shape);          // OS mouse cursor for this frame (0=default,1=resize-EW,2=resize-NS,3=hand,4=I-beam)
void ember_gfx_clipboard_set(const char *text);// copy text to the system clipboard
const char *ember_gfx_clipboard_get(void);     // read the system clipboard (borrowed, copy now)
int  ember_gfx_screen_width(void);             // current window width (resizable)
int  ember_gfx_screen_height(void);            // current window height
void ember_gfx_set_layer(int z);               // z-layer for the draw commands that follow
void ember_gfx_clip_push(int x, int y, int w, int h); // mask following draws to this rect
void ember_gfx_clip_pop(void);                 // end the most recent clip region
int  ember_gfx_tape_open(const char *path);    // start the UI tape -> file; 1 on success
void ember_gfx_tape_close(void);               // stop recording, flush + close
void ember_gfx_tape_mark(const char *kind, const char *label); // record an interaction
// Rich primitives for a modern look. Colors are 0xRRGGBB; `alpha` is 0..255 (so widgets can layer
// translucent fills, borders, gradients, and soft shadows). `radius` is a corner radius in pixels
// (0 = square). These flow through the same deferred layer/clip/tape pipeline as draw_rect.
void ember_gfx_fill_round(int x, int y, int w, int h, int radius, int color, int alpha);
void ember_gfx_stroke_round(int x, int y, int w, int h, int radius, int thick, int color, int alpha);
void ember_gfx_fill_grad(int x, int y, int w, int h, int radius, int top, int bottom, int alpha);
void ember_gfx_shadow(int x, int y, int w, int h, int radius, int alpha);
void ember_gfx_fill_circle(int cx, int cy, int r, int color, int alpha);
int  ember_gfx_mouse_wheel(void);              // scroll notches this frame (+up / -down)
#endif

#endif // EMBER_GRAPHICS_H
