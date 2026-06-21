#include "diag.h"

#include <stdlib.h>
#include <string.h>

// One collected diagnostic. Strings are owned copies (the inputs are often
// transient). A zero `note_line` means there is no secondary location.
typedef struct {
    char *file;
    int   line;
    int   col;
    char *msg;
    char *near;       // or NULL
    char *help;       // or NULL
    char *note_msg;   // secondary label, or NULL
    char *note_file;
    int   note_line;
    int   note_col;
} Diag;

static Diag  *g_diags = NULL;
static int    g_count = 0;
static int    g_cap   = 0;
static int    g_json  = 0;






static char *dup_or_null(const char *s) {
    if (s == NULL) {
        return NULL;
    }
    size_t n = strlen(s);
    char  *p = malloc(n + 1);
    if (p != NULL) {
        memcpy(p, s, n + 1);
    }
    return p;
}






void diag_set_json(int on) {
    g_json = on;
}






int diag_json_enabled(void) {
    return g_json;
}






// print_human renders one diagnostic exactly as the compiler always has, so the
// human stream is byte-identical: the error line, then optional help/note lines
// (absent in slices that do not set them, so nothing changes).
static void print_human(const Diag *d) {
    fprintf(stderr, "%s:%d:%d: error: %s", d->file, d->line, d->col, d->msg);
    if (d->near != NULL) {
        fprintf(stderr, " (near '%s')", d->near);
    }
    fputc('\n', stderr);
    if (d->help != NULL) {
        fprintf(stderr, "%s:%d:%d: help: %s\n", d->file, d->line, d->col, d->help);
    }
    if (d->note_msg != NULL) {
        fprintf(stderr, "%s:%d:%d: note: %s\n",
                d->note_file, d->note_line, d->note_col, d->note_msg);
    }
}






void diag_error(const char *file, int line, int col,
                const char *msg, const char *near, const char *help) {
    if (!g_json) {
        // Human mode: print immediately, no bookkeeping — identical to before.
        Diag d = { (char *)file, line, col, (char *)msg, (char *)near,
                   (char *)help, NULL, NULL, 0, 0 };
        print_human(&d);
        return;
    }
    if (g_count == g_cap) {
        g_cap = g_cap == 0 ? 8 : g_cap * 2;
        g_diags = realloc(g_diags, (size_t)g_cap * sizeof(Diag));
    }
    Diag *d     = &g_diags[g_count++];
    d->file     = dup_or_null(file);
    d->line     = line;
    d->col      = col;
    d->msg      = dup_or_null(msg);
    d->near     = dup_or_null(near);
    d->help     = dup_or_null(help);
    d->note_msg = NULL;
    d->note_file = NULL;
    d->note_line = 0;
    d->note_col  = 0;
}






void diag_note(const char *file, int line, int col, const char *msg) {
    if (!g_json || g_count == 0) {
        if (!g_json) {
            // Human mode: append the note line under the just-printed diagnostic.
            fprintf(stderr, "%s:%d:%d: note: %s\n", file, line, col, msg);
        }
        return;
    }
    Diag *d      = &g_diags[g_count - 1];
    d->note_file = dup_or_null(file);
    d->note_line = line;
    d->note_col  = col;
    d->note_msg  = dup_or_null(msg);
}






// put_json_string writes `s` as a quoted, escaped JSON string (or `null`).
static void put_json_string(FILE *out, const char *s) {
    if (s == NULL) {
        fputs("null", out);
        return;
    }
    fputc('"', out);
    for (const char *p = s; *p != '\0'; p++) {
        unsigned char c = (unsigned char)*p;
        switch (c) {
            case '"':  fputs("\\\"", out); break;
            case '\\': fputs("\\\\", out); break;
            case '\n': fputs("\\n", out);  break;
            case '\r': fputs("\\r", out);  break;
            case '\t': fputs("\\t", out);  break;
            default:
                if (c < 0x20) {
                    fprintf(out, "\\u%04x", c);
                } else {
                    fputc((int)c, out);
                }
        }
    }
    fputc('"', out);
}






void diag_flush_json(FILE *out) {
    for (int i = 0; i < g_count; i++) {
        const Diag *d = &g_diags[i];
        fputs("{\"severity\":\"error\",\"file\":", out);
        put_json_string(out, d->file);
        fprintf(out, ",\"line\":%d,\"col\":%d,\"message\":", d->line, d->col);
        put_json_string(out, d->msg);
        fputs(",\"near\":", out);
        put_json_string(out, d->near);
        fputs(",\"help\":", out);
        put_json_string(out, d->help);
        fputs(",\"note\":", out);
        if (d->note_msg == NULL) {
            fputs("null", out);
        } else {
            fprintf(out, "{\"line\":%d,\"col\":%d,\"message\":",
                    d->note_line, d->note_col);
            put_json_string(out, d->note_msg);
            fputc('}', out);
        }
        fputs("}\n", out);
    }
}






int diag_count(void) {
    return g_count;
}






int diag_at(int i, DiagInfo *out) {
    if (i < 0 || i >= g_count) {
        return 0;
    }
    out->file = g_diags[i].file;
    out->line = g_diags[i].line;
    out->col  = g_diags[i].col;
    out->msg  = g_diags[i].msg;
    return 1;
}






void diag_reset(void) {
    for (int i = 0; i < g_count; i++) {
        free(g_diags[i].file);
        free(g_diags[i].msg);
        free(g_diags[i].near);
        free(g_diags[i].help);
        free(g_diags[i].note_msg);
        free(g_diags[i].note_file);
    }
    free(g_diags);
    g_diags = NULL;
    g_count = 0;
    g_cap   = 0;
}
