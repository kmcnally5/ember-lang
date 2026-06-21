#include "builtin.h"

#include <string.h>

int native_id_for_name(const char *name) {
    if (strcmp(name, "print") == 0) {
        return NATIVE_PRINT;
    }
    if (strcmp(name, "println") == 0) {
        return NATIVE_PRINTLN;
    }
    if (strcmp(name, "read_line") == 0) {
        return NATIVE_READ_LINE;
    }
    if (strcmp(name, "read_file") == 0) {
        return NATIVE_READ_FILE;
    }
    if (strcmp(name, "write_file") == 0) {
        return NATIVE_WRITE_FILE;
    }
    if (strcmp(name, "char_code") == 0)      return NATIVE_CHAR_CODE;
    if (strcmp(name, "from_char_code") == 0) return NATIVE_FROM_CHAR_CODE;
    if (strcmp(name, "parse_float") == 0)    return NATIVE_PARSE_FLOAT;
    if (strcmp(name, "sqrt") == 0)           return NATIVE_SQRT;
    if (strcmp(name, "pow") == 0)            return NATIVE_POW;
    if (strcmp(name, "abs") == 0)            return NATIVE_ABS;
    if (strcmp(name, "floor") == 0)          return NATIVE_FLOOR;
    if (strcmp(name, "ceil") == 0)           return NATIVE_CEIL;
    if (strcmp(name, "round") == 0)          return NATIVE_ROUND;
    if (strcmp(name, "random") == 0)         return NATIVE_RANDOM;
    if (strcmp(name, "hash") == 0)           return NATIVE_HASH;
    if (strcmp(name, "concat") == 0)         return NATIVE_CONCAT;
    if (strcmp(name, "args") == 0)           return NATIVE_ARGS;
    if (strcmp(name, "env") == 0)            return NATIVE_ENV;
    if (strcmp(name, "exit") == 0)           return NATIVE_EXIT;
    // Graphics primitives resolve in EVERY build so the checker/LSP knows their signatures; the
    // implementation is still graphics-only (see the VM / native-backend dispatch).
    if (strcmp(name, "window_open") == 0)         return NATIVE_GFX_WINDOW_OPEN;
    if (strcmp(name, "window_close") == 0)        return NATIVE_GFX_WINDOW_CLOSE;
    if (strcmp(name, "window_should_close") == 0) return NATIVE_GFX_SHOULD_CLOSE;
    if (strcmp(name, "frame_begin") == 0)         return NATIVE_GFX_FRAME_BEGIN;
    if (strcmp(name, "frame_end") == 0)           return NATIVE_GFX_FRAME_END;
    if (strcmp(name, "draw_rect") == 0)           return NATIVE_GFX_DRAW_RECT;
    if (strcmp(name, "draw_text") == 0)           return NATIVE_GFX_DRAW_TEXT;
    if (strcmp(name, "key_down") == 0)            return NATIVE_GFX_KEY_DOWN;
    if (strcmp(name, "mouse_x") == 0)             return NATIVE_GFX_MOUSE_X;
    if (strcmp(name, "mouse_y") == 0)             return NATIVE_GFX_MOUSE_Y;
    if (strcmp(name, "mouse_down") == 0)          return NATIVE_GFX_MOUSE_DOWN;
    if (strcmp(name, "measure_text") == 0)        return NATIVE_GFX_MEASURE_TEXT;
    if (strcmp(name, "text_line_height") == 0)    return NATIVE_GFX_TEXT_LINE_H;
    if (strcmp(name, "char_pressed") == 0)        return NATIVE_GFX_CHAR_PRESSED;
    if (strcmp(name, "key_pressed") == 0)         return NATIVE_GFX_KEY_PRESSED;
    if (strcmp(name, "set_layer") == 0)           return NATIVE_GFX_SET_LAYER;
    if (strcmp(name, "clip_push") == 0)           return NATIVE_GFX_CLIP_PUSH;
    if (strcmp(name, "clip_pop") == 0)            return NATIVE_GFX_CLIP_POP;
    if (strcmp(name, "tape_open") == 0)           return NATIVE_GFX_TAPE_OPEN;
    if (strcmp(name, "tape_close") == 0)          return NATIVE_GFX_TAPE_CLOSE;
    if (strcmp(name, "tape_mark") == 0)           return NATIVE_GFX_TAPE_MARK;
    if (strcmp(name, "fill_round") == 0)          return NATIVE_GFX_FILL_ROUND;
    if (strcmp(name, "stroke_round") == 0)        return NATIVE_GFX_STROKE_ROUND;
    if (strcmp(name, "fill_grad") == 0)           return NATIVE_GFX_FILL_GRAD;
    if (strcmp(name, "shadow") == 0)              return NATIVE_GFX_SHADOW;
    if (strcmp(name, "fill_circle") == 0)         return NATIVE_GFX_FILL_CIRCLE;
    if (strcmp(name, "mouse_wheel") == 0)         return NATIVE_GFX_MOUSE_WHEEL;
    if (strcmp(name, "key_repeat") == 0)          return NATIVE_GFX_KEY_REPEAT;
    if (strcmp(name, "load_font") == 0)           return NATIVE_GFX_LOAD_FONT;
    if (strcmp(name, "set_font") == 0)            return NATIVE_GFX_SET_FONT;
    if (strcmp(name, "set_cursor") == 0)          return NATIVE_GFX_SET_CURSOR;
    if (strcmp(name, "clipboard_set") == 0)       return NATIVE_GFX_CLIPBOARD_SET;
    if (strcmp(name, "clipboard_get") == 0)       return NATIVE_GFX_CLIPBOARD_GET;
    if (strcmp(name, "screen_width") == 0)        return NATIVE_GFX_SCREEN_W;
    if (strcmp(name, "screen_height") == 0)       return NATIVE_GFX_SCREEN_H;
    return -1;
}
