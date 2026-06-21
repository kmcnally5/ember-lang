#ifndef EMBER_JSON_H
#define EMBER_JSON_H

#include <stddef.h>

// A minimal, dependency-free JSON reader + writer for the language server (LSP speaks JSON-RPC).
// Ember already EMITS JSON everywhere (the tape, diagnostics, --emit modes); this is the missing
// half — PARSING incoming JSON — kept in-tree like every other Ember primitive. The reader builds
// a small tagged value tree; the writer is a growable text buffer for building responses.

typedef enum {
    JSON_NULL, JSON_BOOL, JSON_NUM, JSON_STR, JSON_ARRAY, JSON_OBJECT
} JsonKind;

typedef struct JsonValue JsonValue;

// Parse a NUL-terminated JSON document. Returns NULL on malformed input. Free with json_free.
JsonValue *json_parse(const char *text);
void       json_free(JsonValue *v);

JsonKind         json_kind(const JsonValue *v);
const JsonValue *json_get(const JsonValue *obj, const char *key);  // object field, or NULL
const JsonValue *json_at(const JsonValue *arr, int i);             // array element, or NULL
int              json_len(const JsonValue *arr);                   // array length (0 otherwise)
const char      *json_as_str(const JsonValue *v);   // decoded string, or NULL if not a string
double           json_as_num(const JsonValue *v);   // number value, or 0

// A growable text buffer for building JSON-RPC responses.
typedef struct {
    char  *buf;
    size_t len;
    size_t cap;
} JsonBuf;

void json_buf_init(JsonBuf *b);
void json_buf_free(JsonBuf *b);
void json_buf_puts(JsonBuf *b, const char *s);        // append raw text
void json_buf_putc(JsonBuf *b, char c);
void json_buf_put_str(JsonBuf *b, const char *s);     // append `s` as a quoted, escaped JSON string
void json_buf_put_int(JsonBuf *b, long v);
void json_buf_put_value(JsonBuf *b, const JsonValue *v); // re-serialize a parsed value (echo an id)

#endif // EMBER_JSON_H
