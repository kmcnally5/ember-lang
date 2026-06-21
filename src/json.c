#include "json.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// In-tree JSON (see json.h). The reader is a small recursive-descent parser over a NUL-terminated
// buffer; the writer is a geometric-growth text buffer. No third-party dependency, in keeping with
// Ember's empty-dependency-tree rule — the language server links nothing the compiler doesn't.

struct JsonValue {
    JsonKind kind;
    int      boolean;        // JSON_BOOL
    double   num;            // JSON_NUM
    char    *str;            // JSON_STR (decoded, owned)
    JsonValue **items;       // JSON_ARRAY
    int        count;        // array length / object pair count
    char     **keys;         // JSON_OBJECT (owned)
    JsonValue **vals;        // JSON_OBJECT
};





// ---- reader -----------------------------------------------------------------------------------

typedef struct {
    const char *p;
    int         ok;
} Parser;





static JsonValue *jv_new(JsonKind k) {
    JsonValue *v = calloc(1, sizeof(JsonValue));
    if (v != NULL) {
        v->kind = k;
    }
    return v;
}





static void skip_ws(Parser *ps) {
    while (*ps->p == ' ' || *ps->p == '\t' || *ps->p == '\n' || *ps->p == '\r') {
        ps->p++;
    }
}





// A small growable byte buffer for decoding a string literal's contents.
typedef struct {
    char  *b;
    size_t len;
    size_t cap;
} Bytes;





static void bytes_push(Bytes *o, char c) {
    if (o->len + 1 > o->cap) {
        o->cap = o->cap ? o->cap * 2 : 32;
        o->b   = realloc(o->b, o->cap);
    }
    o->b[o->len++] = c;
}





// Encode a Unicode code point as UTF-8 (so \uXXXX escapes round-trip through document text).
static void bytes_push_utf8(Bytes *o, unsigned cp) {
    if (cp < 0x80) {
        bytes_push(o, (char)cp);
    } else if (cp < 0x800) {
        bytes_push(o, (char)(0xC0 | (cp >> 6)));
        bytes_push(o, (char)(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        bytes_push(o, (char)(0xE0 | (cp >> 12)));
        bytes_push(o, (char)(0x80 | ((cp >> 6) & 0x3F)));
        bytes_push(o, (char)(0x80 | (cp & 0x3F)));
    } else {
        bytes_push(o, (char)(0xF0 | (cp >> 18)));
        bytes_push(o, (char)(0x80 | ((cp >> 12) & 0x3F)));
        bytes_push(o, (char)(0x80 | ((cp >> 6) & 0x3F)));
        bytes_push(o, (char)(0x80 | (cp & 0x3F)));
    }
}





static unsigned parse_hex4(Parser *ps) {
    unsigned v = 0;
    for (int i = 0; i < 4; i++) {
        char c = *ps->p;
        v <<= 4;
        if (c >= '0' && c <= '9') {
            v |= (unsigned)(c - '0');
        } else if (c >= 'a' && c <= 'f') {
            v |= (unsigned)(c - 'a' + 10);
        } else if (c >= 'A' && c <= 'F') {
            v |= (unsigned)(c - 'A' + 10);
        } else {
            ps->ok = 0;
            return 0;
        }
        ps->p++;
    }
    return v;
}





// Parse a JSON string body (the opening quote already consumed). Returns an owned, decoded buffer.
static char *parse_string_raw(Parser *ps) {
    Bytes o = {0};
    while (*ps->p != '\0' && *ps->p != '"') {
        char c = *ps->p;
        if (c == '\\') {
            ps->p++;
            char e = *ps->p;
            switch (e) {
                case '"':  bytes_push(&o, '"');  ps->p++; break;
                case '\\': bytes_push(&o, '\\'); ps->p++; break;
                case '/':  bytes_push(&o, '/');  ps->p++; break;
                case 'b':  bytes_push(&o, '\b'); ps->p++; break;
                case 'f':  bytes_push(&o, '\f'); ps->p++; break;
                case 'n':  bytes_push(&o, '\n'); ps->p++; break;
                case 'r':  bytes_push(&o, '\r'); ps->p++; break;
                case 't':  bytes_push(&o, '\t'); ps->p++; break;
                case 'u': {
                    ps->p++;
                    unsigned cp = parse_hex4(ps);
                    if (!ps->ok) { free(o.b); return NULL; }
                    if (cp >= 0xD800 && cp <= 0xDBFF && ps->p[0] == '\\' && ps->p[1] == 'u') {
                        ps->p += 2;
                        unsigned lo = parse_hex4(ps);
                        if (!ps->ok) { free(o.b); return NULL; }
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    bytes_push_utf8(&o, cp);
                    break;
                }
                default: ps->ok = 0; free(o.b); return NULL;
            }
        } else {
            bytes_push(&o, c);
            ps->p++;
        }
    }
    if (*ps->p != '"') {
        ps->ok = 0;
        free(o.b);
        return NULL;
    }
    ps->p++;                  // closing quote
    bytes_push(&o, '\0');
    return o.b != NULL ? o.b : calloc(1, 1);
}





static JsonValue *parse_value(Parser *ps);   // forward





static JsonValue *parse_string(Parser *ps) {
    ps->p++;                  // opening quote
    char *s = parse_string_raw(ps);
    if (!ps->ok) {
        return NULL;
    }
    JsonValue *v = jv_new(JSON_STR);
    v->str = s;
    return v;
}





static JsonValue *parse_array(Parser *ps) {
    ps->p++;                  // [
    JsonValue *v = jv_new(JSON_ARRAY);
    skip_ws(ps);
    if (*ps->p == ']') { ps->p++; return v; }
    for (;;) {
        JsonValue *e = parse_value(ps);
        if (!ps->ok) { json_free(v); return NULL; }
        v->items = realloc(v->items, (size_t)(v->count + 1) * sizeof(JsonValue *));
        v->items[v->count++] = e;
        skip_ws(ps);
        if (*ps->p == ',') { ps->p++; skip_ws(ps); continue; }
        if (*ps->p == ']') { ps->p++; break; }
        ps->ok = 0; json_free(v); return NULL;
    }
    return v;
}





static JsonValue *parse_object(Parser *ps) {
    ps->p++;                  // {
    JsonValue *v = jv_new(JSON_OBJECT);
    skip_ws(ps);
    if (*ps->p == '}') { ps->p++; return v; }
    for (;;) {
        skip_ws(ps);
        if (*ps->p != '"') { ps->ok = 0; json_free(v); return NULL; }
        ps->p++;
        char *key = parse_string_raw(ps);
        if (!ps->ok) { json_free(v); return NULL; }
        skip_ws(ps);
        if (*ps->p != ':') { ps->ok = 0; free(key); json_free(v); return NULL; }
        ps->p++;
        JsonValue *val = parse_value(ps);
        if (!ps->ok) { free(key); json_free(v); return NULL; }
        v->keys = realloc(v->keys, (size_t)(v->count + 1) * sizeof(char *));
        v->vals = realloc(v->vals, (size_t)(v->count + 1) * sizeof(JsonValue *));
        v->keys[v->count] = key;
        v->vals[v->count] = val;
        v->count++;
        skip_ws(ps);
        if (*ps->p == ',') { ps->p++; continue; }
        if (*ps->p == '}') { ps->p++; break; }
        ps->ok = 0; json_free(v); return NULL;
    }
    return v;
}





static JsonValue *parse_value(Parser *ps) {
    skip_ws(ps);
    char c = *ps->p;
    if (c == '"') {
        return parse_string(ps);
    }
    if (c == '{') {
        return parse_object(ps);
    }
    if (c == '[') {
        return parse_array(ps);
    }
    if (c == 't') {
        if (strncmp(ps->p, "true", 4) != 0) { ps->ok = 0; return NULL; }
        ps->p += 4;
        JsonValue *v = jv_new(JSON_BOOL); v->boolean = 1; return v;
    }
    if (c == 'f') {
        if (strncmp(ps->p, "false", 5) != 0) { ps->ok = 0; return NULL; }
        ps->p += 5;
        JsonValue *v = jv_new(JSON_BOOL); v->boolean = 0; return v;
    }
    if (c == 'n') {
        if (strncmp(ps->p, "null", 4) != 0) { ps->ok = 0; return NULL; }
        ps->p += 4;
        return jv_new(JSON_NULL);
    }
    if (c == '-' || (c >= '0' && c <= '9')) {
        char *end = NULL;
        double d = strtod(ps->p, &end);
        if (end == ps->p) { ps->ok = 0; return NULL; }
        ps->p = end;
        JsonValue *v = jv_new(JSON_NUM); v->num = d; return v;
    }
    ps->ok = 0;
    return NULL;
}





JsonValue *json_parse(const char *text) {
    Parser ps = { text, 1 };
    JsonValue *v = parse_value(&ps);
    if (!ps.ok) {
        json_free(v);
        return NULL;
    }
    return v;
}





void json_free(JsonValue *v) {
    if (v == NULL) {
        return;
    }
    if (v->kind == JSON_STR) {
        free(v->str);
    } else if (v->kind == JSON_ARRAY) {
        for (int i = 0; i < v->count; i++) {
            json_free(v->items[i]);
        }
        free(v->items);
    } else if (v->kind == JSON_OBJECT) {
        for (int i = 0; i < v->count; i++) {
            free(v->keys[i]);
            json_free(v->vals[i]);
        }
        free(v->keys);
        free(v->vals);
    }
    free(v);
}





// ---- accessors --------------------------------------------------------------------------------

JsonKind json_kind(const JsonValue *v) {
    return v == NULL ? JSON_NULL : v->kind;
}





const JsonValue *json_get(const JsonValue *obj, const char *key) {
    if (obj == NULL || obj->kind != JSON_OBJECT) {
        return NULL;
    }
    for (int i = 0; i < obj->count; i++) {
        if (strcmp(obj->keys[i], key) == 0) {
            return obj->vals[i];
        }
    }
    return NULL;
}





const JsonValue *json_at(const JsonValue *arr, int i) {
    if (arr == NULL || arr->kind != JSON_ARRAY || i < 0 || i >= arr->count) {
        return NULL;
    }
    return arr->items[i];
}





int json_len(const JsonValue *arr) {
    return (arr != NULL && arr->kind == JSON_ARRAY) ? arr->count : 0;
}





const char *json_as_str(const JsonValue *v) {
    return (v != NULL && v->kind == JSON_STR) ? v->str : NULL;
}





double json_as_num(const JsonValue *v) {
    return (v != NULL && v->kind == JSON_NUM) ? v->num : 0.0;
}





// ---- writer -----------------------------------------------------------------------------------

void json_buf_init(JsonBuf *b) {
    b->buf = NULL;
    b->len = 0;
    b->cap = 0;
}





void json_buf_free(JsonBuf *b) {
    free(b->buf);
    b->buf = NULL;
    b->len = 0;
    b->cap = 0;
}





static void json_buf_reserve(JsonBuf *b, size_t extra) {
    if (b->len + extra + 1 > b->cap) {
        size_t want = b->cap ? b->cap : 256;
        while (b->len + extra + 1 > want) {
            want *= 2;
        }
        b->buf = realloc(b->buf, want);
        b->cap = want;
    }
}





void json_buf_putc(JsonBuf *b, char c) {
    json_buf_reserve(b, 1);
    b->buf[b->len++] = c;
    b->buf[b->len]   = '\0';
}





void json_buf_puts(JsonBuf *b, const char *s) {
    size_t n = strlen(s);
    json_buf_reserve(b, n);
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = '\0';
}





void json_buf_put_str(JsonBuf *b, const char *s) {
    json_buf_putc(b, '"');
    for (const char *p = s; *p != '\0'; p++) {
        unsigned char c = (unsigned char)*p;
        switch (c) {
            case '"':  json_buf_puts(b, "\\\""); break;
            case '\\': json_buf_puts(b, "\\\\"); break;
            case '\n': json_buf_puts(b, "\\n");  break;
            case '\r': json_buf_puts(b, "\\r");  break;
            case '\t': json_buf_puts(b, "\\t");  break;
            default:
                if (c < 0x20) {
                    char tmp[8];
                    snprintf(tmp, sizeof tmp, "\\u%04x", c);
                    json_buf_puts(b, tmp);
                } else {
                    json_buf_putc(b, (char)c);
                }
        }
    }
    json_buf_putc(b, '"');
}





void json_buf_put_int(JsonBuf *b, long v) {
    char tmp[32];
    snprintf(tmp, sizeof tmp, "%ld", v);
    json_buf_puts(b, tmp);
}





void json_buf_put_value(JsonBuf *b, const JsonValue *v) {
    if (v == NULL || v->kind == JSON_NULL) {
        json_buf_puts(b, "null");
        return;
    }
    switch (v->kind) {
        case JSON_BOOL:
            json_buf_puts(b, v->boolean ? "true" : "false");
            break;
        case JSON_NUM: {
            char tmp[32];
            if (v->num == (long)v->num) {
                snprintf(tmp, sizeof tmp, "%ld", (long)v->num);   // ids are usually integers
            } else {
                snprintf(tmp, sizeof tmp, "%g", v->num);
            }
            json_buf_puts(b, tmp);
            break;
        }
        case JSON_STR:
            json_buf_put_str(b, v->str);
            break;
        case JSON_ARRAY:
            json_buf_putc(b, '[');
            for (int i = 0; i < v->count; i++) {
                if (i > 0) { json_buf_putc(b, ','); }
                json_buf_put_value(b, v->items[i]);
            }
            json_buf_putc(b, ']');
            break;
        case JSON_OBJECT:
            json_buf_putc(b, '{');
            for (int i = 0; i < v->count; i++) {
                if (i > 0) { json_buf_putc(b, ','); }
                json_buf_put_str(b, v->keys[i]);
                json_buf_putc(b, ':');
                json_buf_put_value(b, v->vals[i]);
            }
            json_buf_putc(b, '}');
            break;
        default:
            json_buf_puts(b, "null");
    }
}
