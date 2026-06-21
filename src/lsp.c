#include "lsp.h"
#include "json.h"
#include "driver.h"
#include "lexer.h"
#include "parser.h"
#include "arena.h"
#include "ast.h"
#include "token.h"
#include "diag.h"
#include "semindex.h"
#include "typefmt.h"
#include "prove.h"
#include "version.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <limits.h>
#include <ctype.h>

// The Ember language server (see lsp.h). Slice 1+2: JSON-RPC over stdio, the document lifecycle
// (initialize/shutdown, didOpen/didChange/didClose), and live diagnostics produced by running the
// REAL front end (driver.h's compile_program) on the in-memory buffer and mapping collected
// diagnostics (diag.h) to textDocument/publishDiagnostics. No second parser/checker — the editor
// sees exactly what `emberc` sees. stdout carries the protocol; stderr is free for logging.





// ---- transport (LSP base protocol: `Content-Length` framing over stdio) ------------------------

// read_message reads one framed message body (NUL-terminated, owned), or NULL at end of stream.
static char *read_message(void) {
    long content_length = -1;
    for (;;) {
        char line[512];
        int  n = 0;
        int  c;
        while ((c = getchar()) != EOF && c != '\n') {
            if (n < (int)sizeof(line) - 1) {
                line[n++] = (char)c;
            }
        }
        if (c == EOF && n == 0) {
            return NULL;                       // stream closed
        }
        if (n > 0 && line[n - 1] == '\r') {
            n--;
        }
        line[n] = '\0';
        if (n == 0) {
            break;                             // blank line ends the headers
        }
        if (strncmp(line, "Content-Length:", 15) == 0) {
            content_length = strtol(line + 15, NULL, 10);
        }
    }
    if (content_length < 0) {
        return NULL;
    }
    char  *body = malloc((size_t)content_length + 1);
    size_t got  = 0;
    while (got < (size_t)content_length) {
        size_t r = fread(body + got, 1, (size_t)content_length - got, stdin);
        if (r == 0) {
            break;
        }
        got += r;
    }
    body[got] = '\0';
    return body;
}





// write_message frames and sends one JSON message body to the client.
static void write_message(const char *body) {
    printf("Content-Length: %zu\r\n\r\n", strlen(body));
    fwrite(body, 1, strlen(body), stdout);
    fflush(stdout);
}





// ---- position encoding (LSP positionEncoding negotiation, LSP 3.17) ----------------------------
// LSP positions are (line, character); the unit of "character" is the negotiated positionEncoding.
// "utf-8" => byte offset, which is exactly what Ember's lexer tracks (Token.col/length are bytes).
// "utf-16" (the protocol default) => UTF-16 code-unit offset. The whole compiler works in bytes, so
// when a client only speaks utf-16 we translate columns at the wire. An ASCII line — almost all
// Ember source — is identity in either encoding; only a line carrying a byte >= 0x80 (non-ASCII in
// a comment or string literal) is walked. Lines are encoding-independent and never converted.

static int g_pos_utf16 = 0;   // 1 once the client negotiated utf-16 (or sent no positionEncodings)





// utf8_seq_len returns the byte length of the UTF-8 sequence led by `c` (1 for ASCII / invalid).
static int utf8_seq_len(unsigned char c) {
    if (c < 0x80)           return 1;
    if ((c & 0xE0) == 0xC0) return 2;
    if ((c & 0xF0) == 0xE0) return 3;
    if ((c & 0xF8) == 0xF0) return 4;
    return 1;
}





// utf8_utf16_units returns how many UTF-16 code units the sequence led by `c` encodes: a 4-byte
// (astral) sequence is a surrogate pair (2 units); everything else is one.
static int utf8_utf16_units(unsigned char c) {
    return ((c & 0xF8) == 0xF0) ? 2 : 1;
}





// line_start returns a pointer to the first byte of 0-based `line0` in `text` (or the trailing NUL
// when `line0` is past the end).
static const char *line_start(const char *text, int line0) {
    const char *p = text;
    int         l = 0;
    while (l < line0 && *p != '\0') {
        if (*p == '\n') {
            l++;
        }
        p++;
    }
    return p;
}





// byte_to_char converts a 0-based BYTE column on `line0` into the column the client expects (a
// UTF-16 code unit when utf-16 was negotiated; otherwise the byte column unchanged). Used on every
// OUTGOING position (diagnostics, definition/symbol ranges).
static int byte_to_char(const char *text, int line0, int byte_col) {
    if (!g_pos_utf16 || text == NULL || byte_col <= 0) {
        return byte_col;
    }
    const char *p = line_start(text, line0);
    int         b = 0;
    int         u = 0;
    while (b < byte_col && p[b] != '\0' && p[b] != '\n') {
        unsigned char c = (unsigned char)p[b];
        b += utf8_seq_len(c);
        u += utf8_utf16_units(c);
    }
    return u;
}





// char_to_byte is the inverse: it converts a 0-based column from the client (UTF-16 under utf-16)
// into a BYTE column the compiler can match against token positions. Used on every INCOMING
// position (hover / definition / completion).
static int char_to_byte(const char *text, int line0, int char_col) {
    if (!g_pos_utf16 || text == NULL || char_col <= 0) {
        return char_col;
    }
    const char *p = line_start(text, line0);
    int         b = 0;
    int         u = 0;
    while (u < char_col && p[b] != '\0' && p[b] != '\n') {
        unsigned char c = (unsigned char)p[b];
        b += utf8_seq_len(c);
        u += utf8_utf16_units(c);
    }
    return b;
}





// client_supports_utf8 reports whether the client listed "utf-8" in
// capabilities.general.positionEncodings (LSP 3.17). When it is absent the only encoding the client
// guarantees is the utf-16 default, so we must speak utf-16.
static int client_supports_utf8(const JsonValue *params) {
    const JsonValue *encs = json_get(json_get(json_get(params, "capabilities"), "general"),
                                     "positionEncodings");
    int n = json_len(encs);
    for (int i = 0; i < n; i++) {
        const char *e = json_as_str(json_at(encs, i));
        if (e != NULL && strcmp(e, "utf-8") == 0) {
            return 1;
        }
    }
    return 0;
}





// ---- open-document store (full-sync: the client sends the whole buffer each change) ------------

typedef struct {
    char *uri;
    char *path;     // filesystem path derived from the uri (for imports + diagnostic matching)
    char *text;
} Doc;

static Doc *g_docs;
static int  g_doc_count;
static int  g_doc_cap;

// The workspace root, captured at `initialize` (rootUri / workspaceFolders). Project-wide
// find-references and rename walk it for `.em` files. NULL until initialize, or when the client
// opens a single file with no folder — callers then fall back to the active document's directory.
static char *g_root_path;





// uri_to_path turns a `file://` URI into a filesystem path, percent-decoding %XX escapes.
static char *uri_to_path(const char *uri) {
    const char *s = uri;
    if (strncmp(s, "file://", 7) == 0) {
        s += 7;                                // file:///Users/... -> /Users/...
    }
    char  *out = malloc(strlen(s) + 1);
    size_t o   = 0;
    for (const char *p = s; *p != '\0'; p++) {
        if (p[0] == '%' && p[1] != '\0' && p[2] != '\0') {
            char hex[3] = { p[1], p[2], '\0' };
            out[o++] = (char)strtol(hex, NULL, 16);
            p += 2;
        } else {
            out[o++] = *p;
        }
    }
    out[o] = '\0';
    return out;
}





// path_to_uri turns a filesystem path into a `file://` URI, percent-encoding bytes outside the
// URL-safe set (the inverse of uri_to_path). Used to point cross-file go-to-definition at an
// imported module's source. Caller frees.
static char *path_to_uri(const char *path) {
    static const char safe[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
                               "0123456789-._~/";
    static const char hex[]  = "0123456789ABCDEF";
    size_t n   = strlen(path);
    char  *out = malloc(7 + n * 3 + 1);
    memcpy(out, "file://", 7);
    size_t o = 7;
    for (size_t i = 0; i < n; i++) {
        unsigned char ch = (unsigned char)path[i];
        if (strchr(safe, ch) != NULL) {
            out[o++] = (char)ch;
        } else {
            out[o++] = '%';
            out[o++] = hex[ch >> 4];
            out[o++] = hex[ch & 0xF];
        }
    }
    out[o] = '\0';
    return out;
}




static Doc *doc_find(const char *uri) {
    for (int i = 0; i < g_doc_count; i++) {
        if (strcmp(g_docs[i].uri, uri) == 0) {
            return &g_docs[i];
        }
    }
    return NULL;
}





// doc_upsert stores (or replaces) the text for `uri`, returning the entry.
static Doc *doc_upsert(const char *uri, const char *text) {
    Doc *d = doc_find(uri);
    if (d == NULL) {
        if (g_doc_count == g_doc_cap) {
            g_doc_cap = g_doc_cap ? g_doc_cap * 2 : 8;
            g_docs    = realloc(g_docs, (size_t)g_doc_cap * sizeof(Doc));
        }
        d = &g_docs[g_doc_count++];
        d->uri  = strdup(uri);
        d->path = uri_to_path(uri);
        d->text = NULL;
    }
    free(d->text);
    d->text = strdup(text != NULL ? text : "");
    return d;
}





static void doc_remove(const char *uri) {
    for (int i = 0; i < g_doc_count; i++) {
        if (strcmp(g_docs[i].uri, uri) == 0) {
            free(g_docs[i].uri);
            free(g_docs[i].path);
            free(g_docs[i].text);
            g_docs[i] = g_docs[--g_doc_count];   // swap-remove (order does not matter)
            return;
        }
    }
}





// ---- parse + AST queries (hover / definition / completion / symbols) --------------------------
// These features answer from the parsed AST (the parser recovers from errors, so the tree is
// usable mid-edit). Names in the AST are arena_strndup'd, so they are NUL-terminated and safely
// strcmp-able. The document is re-parsed per request — fine for a young language with small files;
// caching is a later refinement.

typedef struct {
    Arena     arena;
    TokenList toks;
    Program   prog;
} Parsed;





static void parse_doc(const Doc *d, Parsed *out) {
    arena_init(&out->arena, 0);
    out->toks = lexer_scan(d->text, d->path);
    int perr  = 0;
    out->prog = parser_parse(out->toks.tokens, out->toks.count, &out->arena, d->path, &perr);
}





static void parsed_free(Parsed *p) {
    token_list_free(&p->toks);
    arena_free(&p->arena);
}




// doc_build_index runs the real type checker over the document and leaves a semantic index
// (identifier → inferred type + definition site) in `ix`. This is the SAME front end the compiler
// runs, so hover and go-to-definition reflect exactly what the checker resolved — no second
// analysis (LSP_ROADMAP.md, Phase 2). Diagnostics raised during the pass are discarded here:
// publish_diagnostics owns reporting. The caller must semindex_free the result.
static void doc_build_index(const Doc *d, SemanticIndex *ix) {
    semindex_init(ix);
    diag_reset();
    TokenList toks = lexer_scan(d->text, d->path);
    collect_semantic_index(&toks, d->path, ix);
    token_list_free(&toks);
    diag_reset();
}





// copy_tok copies a token's source text into `buf` as a NUL-terminated string.
static void copy_tok(const Token *t, char *buf, size_t cap) {
    size_t n = t->length < cap - 1 ? t->length : cap - 1;
    memcpy(buf, t->start, n);
    buf[n] = '\0';
}





// token_at returns the token covering the LSP position (0-based line/character), or NULL. Positions
// in tokens are 1-based; an identifier spans [col, col+length).
static const Token *token_at(const TokenList *toks, int line0, int char0) {
    int eline = line0 + 1;
    int ecol  = char0 + 1;
    for (size_t i = 0; i < toks->count; i++) {
        const Token *t = &toks->tokens[i];
        if (t->line == eline && t->col <= ecol && ecol < t->col + (int)t->length) {
            return t;
        }
    }
    return NULL;
}




// member_receiver returns the receiver identifier of a member-access completion at the cursor —
// the `x` in `x.` or `x.par|tial` — or NULL when the cursor is not after a `name.`. It works off
// the token stream: the last token starting before the cursor is the `.` (just typed) or the
// partial field name after it; the token before that `.` is the receiver. Only a bare identifier
// (or `self`) receiver is resolved for now; chained `a.b.` access waits on field-type recording.
static const Token *member_receiver(const TokenList *toks, int line0, int char0) {
    int eline = line0 + 1;
    int ecol  = char0 + 1;
    int last  = -1;
    for (size_t i = 0; i < toks->count; i++) {
        const Token *t = &toks->tokens[i];
        if (t->line == eline && t->col < ecol) {
            last = (int)i;
        }
    }
    if (last < 0) {
        return NULL;
    }
    int dot = -1;
    if (toks->tokens[last].type == TOK_DOT) {
        dot = last;                                   // `x.|`
    } else if (toks->tokens[last].type == TOK_IDENT && last >= 1 &&
               toks->tokens[last - 1].type == TOK_DOT) {
        dot = last - 1;                               // `x.par|tial`
    }
    if (dot < 1) {
        return NULL;
    }
    const Token *recv = &toks->tokens[dot - 1];
    if (recv->type != TOK_IDENT && recv->type != TOK_SELF) {
        return NULL;
    }
    return recv;
}





// jsonbuf_sink_put adapts a JsonBuf to the shared formatter's TypeSink (typefmt.h).
static void jsonbuf_sink_put(void *ctx, const char *s) {
    json_buf_puts((JsonBuf *)ctx, s);
}

// type_str renders a type's surface form into `b` via the one shared surface-syntax formatter
// (src/typefmt.c), so hover and the docs generator can never disagree (OFI-034).
static void type_str(const Type *t, JsonBuf *b) {
    TypeSink sink = { jsonbuf_sink_put, b };
    typefmt_type(&sink, t);
}





// fn_sig renders a function's signature into `b` via the shared formatter (src/typefmt.c).
static void fn_sig(const FnDecl *fn, JsonBuf *b) {
    TypeSink sink = { jsonbuf_sink_put, b };
    typefmt_fn(&sink, fn);
}





// put_range_obj appends a `{"start":…,"end":…}` range value (0-based) spanning `len` bytes from a
// 1-based (line, col). `text` is the source the range lives in (used to translate byte columns to
// the negotiated client encoding); pass NULL when the source is unavailable — declaration lines are
// ASCII before the name, so identity is correct there.
static void put_range_obj(JsonBuf *b, const char *text, int line1, int col1, int len) {
    int l     = line1 > 0 ? line1 - 1 : 0;
    int c_b   = col1  > 0 ? col1  - 1 : 0;
    int end_b = c_b + (len > 0 ? len : 1);
    int c     = byte_to_char(text, l, c_b);
    int end   = byte_to_char(text, l, end_b);
    json_buf_puts(b, "{\"start\":{\"line\":");
    json_buf_put_int(b, l);
    json_buf_puts(b, ",\"character\":");
    json_buf_put_int(b, c);
    json_buf_puts(b, "},\"end\":{\"line\":");
    json_buf_put_int(b, l);
    json_buf_puts(b, ",\"character\":");
    json_buf_put_int(b, end);
    json_buf_puts(b, "}}");
}





// decl_name returns a top-level declaration's name, or NULL if it has none of interest here.
static const char *decl_name(const Decl *d) {
    switch (d->kind) {
        case DECL_FN:        return d->as.fn.name;
        case DECL_STRUCT:    return d->as.struct_.name;
        case DECL_ENUM:      return d->as.enum_.name;
        case DECL_INTERFACE: return d->as.interface.name;
        case DECL_LET:       return d->as.let.name;
        default:             return NULL;
    }
}





// find_decl returns the top-level declaration named `name`, or NULL.
static const Decl *find_decl(const Program *prog, const char *name) {
    for (size_t i = 0; i < prog->count; i++) {
        const char *n = decl_name(prog->decls[i]);
        if (n != NULL && strcmp(n, name) == 0) {
            return prog->decls[i];
        }
    }
    return NULL;
}





// decl_detail appends a one-line description of a declaration (for hover / completion detail).
static void decl_detail(const Decl *d, JsonBuf *b) {
    switch (d->kind) {
        case DECL_FN:        fn_sig(&d->as.fn, b); break;
        case DECL_STRUCT:    json_buf_puts(b, "struct ");    json_buf_puts(b, d->as.struct_.name); break;
        case DECL_ENUM:      json_buf_puts(b, "enum ");      json_buf_puts(b, d->as.enum_.name); break;
        case DECL_INTERFACE: json_buf_puts(b, "interface "); json_buf_puts(b, d->as.interface.name); break;
        case DECL_LET:
            json_buf_puts(b, "let ");
            json_buf_puts(b, d->as.let.name);
            if (d->as.let.type != NULL) {
                json_buf_puts(b, ": ");
                type_str(d->as.let.type, b);
            }
            break;
        default: break;
    }
}





// lsp_kind / sym_kind map a declaration to the LSP CompletionItemKind / SymbolKind enums.
static int completion_kind(DeclKind k) {
    switch (k) {
        case DECL_FN:        return 3;   // Function
        case DECL_STRUCT:    return 22;  // Struct
        case DECL_ENUM:      return 13;  // Enum
        case DECL_INTERFACE: return 8;   // Interface
        case DECL_LET:       return 6;   // Variable
        default:             return 1;   // Text
    }
}





static int symbol_kind(DeclKind k) {
    switch (k) {
        case DECL_FN:        return 12;  // Function
        case DECL_STRUCT:    return 23;  // Struct
        case DECL_ENUM:      return 10;  // Enum
        case DECL_INTERFACE: return 11;  // Interface
        case DECL_LET:       return 13;  // Variable
        default:             return 13;
    }
}





// ---- diagnostics --------------------------------------------------------------------------------

// tok_len returns the length (in bytes) of the token that starts at 1-based (line, col), or 1 if
// none matches — so a diagnostic underlines its whole offending token, not a single character.
static int tok_len(const TokenList *toks, int line, int col) {
    for (size_t i = 0; i < toks->count; i++) {
        if (toks->tokens[i].line == line && toks->tokens[i].col == col) {
            int len = (int)toks->tokens[i].length;
            return len > 0 ? len : 1;
        }
    }
    return 1;
}





// publish_diagnostics compiles `d` with the real front end and sends the resulting diagnostics to
// the client. Only diagnostics in this document (by path) are reported; imported-module errors are
// out of scope for this slice (cross-file diagnostics come later).
static void publish_diagnostics(const Doc *d) {
    diag_reset();
    TokenList toks = lexer_scan(d->text, d->path);
    // Type-check only — the editor wants SEMANTIC diagnostics, not codegen results, and this lets
    // the LSP check programs the running build can't lower (e.g. graphics, whose signatures the
    // checker always knows). Diagnostics are left in the diag buffer; we read and filter them below.
    check_diagnostics(&toks, d->path);

    JsonBuf b;
    json_buf_init(&b);
    json_buf_puts(&b, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\","
                      "\"params\":{\"uri\":");
    json_buf_put_str(&b, d->uri);
    json_buf_puts(&b, ",\"diagnostics\":[");
    int emitted = 0;
    int n = diag_count();
    for (int i = 0; i < n; i++) {
        DiagInfo di;
        if (!diag_at(i, &di)) {
            continue;
        }
        if (di.file != NULL && strcmp(di.file, d->path) != 0) {
            continue;                          // a diagnostic from another (imported) file
        }
        int line   = di.line > 0 ? di.line - 1 : 0;    // LSP positions are 0-based
        int col_b  = di.col  > 0 ? di.col  - 1 : 0;    // byte columns (what the lexer tracks)
        int endc_b = col_b + tok_len(&toks, di.line, di.col);
        int col    = byte_to_char(d->text, line, col_b);   // translate to the negotiated encoding
        int endc   = byte_to_char(d->text, line, endc_b);
        if (emitted > 0) {
            json_buf_putc(&b, ',');
        }
        json_buf_puts(&b, "{\"range\":{\"start\":{\"line\":");
        json_buf_put_int(&b, line);
        json_buf_puts(&b, ",\"character\":");
        json_buf_put_int(&b, col);
        json_buf_puts(&b, "},\"end\":{\"line\":");
        json_buf_put_int(&b, line);
        json_buf_puts(&b, ",\"character\":");
        json_buf_put_int(&b, endc);
        json_buf_puts(&b, "}},\"severity\":1,\"source\":\"emberc\",\"message\":");
        json_buf_put_str(&b, di.msg != NULL ? di.msg : "error");
        json_buf_putc(&b, '}');
        emitted++;
    }
    json_buf_puts(&b, "]}}");
    write_message(b.buf);
    json_buf_free(&b);

    token_list_free(&toks);
    diag_reset();
}





// ---- request handlers ---------------------------------------------------------------------------

// respond sends a result object for a request id. `result_json` is the already-built result value.
static void respond(const JsonValue *id, const char *result_json) {
    JsonBuf b;
    json_buf_init(&b);
    json_buf_puts(&b, "{\"jsonrpc\":\"2.0\",\"id\":");
    json_buf_put_value(&b, id);
    json_buf_puts(&b, ",\"result\":");
    json_buf_puts(&b, result_json);
    json_buf_putc(&b, '}');
    write_message(b.buf);
    json_buf_free(&b);
}





static void handle_did_open(const JsonValue *params) {
    const JsonValue *td   = json_get(params, "textDocument");
    const char      *uri  = json_as_str(json_get(td, "uri"));
    const char      *text = json_as_str(json_get(td, "text"));
    if (uri == NULL) {
        return;
    }
    Doc *d = doc_upsert(uri, text);
    publish_diagnostics(d);
}





static void handle_did_change(const JsonValue *params) {
    const JsonValue *td      = json_get(params, "textDocument");
    const char      *uri     = json_as_str(json_get(td, "uri"));
    const JsonValue *changes = json_get(params, "contentChanges");
    int              n       = json_len(changes);
    if (uri == NULL || n == 0) {
        return;
    }
    // Full sync (textDocumentSync = 1): the last change carries the whole document.
    const char *text = json_as_str(json_get(json_at(changes, n - 1), "text"));
    if (text == NULL) {
        return;
    }
    Doc *d = doc_upsert(uri, text);
    publish_diagnostics(d);
}





static void handle_did_close(const JsonValue *params) {
    const JsonValue *td  = json_get(params, "textDocument");
    const char      *uri = json_as_str(json_get(td, "uri"));
    if (uri == NULL) {
        return;
    }
    doc_remove(uri);
    // Clear the editor's squiggles for the closed file.
    JsonBuf b;
    json_buf_init(&b);
    json_buf_puts(&b, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\","
                      "\"params\":{\"uri\":");
    json_buf_put_str(&b, uri);
    json_buf_puts(&b, ",\"diagnostics\":[]}}");
    write_message(b.buf);
    json_buf_free(&b);
}





// doc_for_params resolves params.textDocument.uri to an open document, or NULL.
static Doc *doc_for_params(const JsonValue *params) {
    const char *uri = json_as_str(json_get(json_get(params, "textDocument"), "uri"));
    return uri != NULL ? doc_find(uri) : NULL;
}





// decl_under_cursor parses `d` into `ps` and returns the top-level declaration whose name is the
// identifier at the request's position, or NULL. The caller owns `ps` and must parsed_free it.
static const Decl *decl_under_cursor(Doc *d, const JsonValue *params, Parsed *ps) {
    parse_doc(d, ps);
    const JsonValue *pos = json_get(params, "position");
    int line0 = (int)json_as_num(json_get(pos, "line"));
    int char0 = (int)json_as_num(json_get(pos, "character"));
    char0 = char_to_byte(d->text, line0, char0);   // client encoding -> byte column for matching
    const Token *t = token_at(&ps->toks, line0, char0);
    if (t == NULL || t->type != TOK_IDENT) {
        return NULL;
    }
    char name[256];
    copy_tok(t, name, sizeof name);
    return find_decl(&ps->prog, name);
}





// A documentation card for a name the AST can't describe on its own: a built-in function or a
// primitive type. `sig` is rendered in the ```ember fence; `doc` is the prose beneath it. The
// signatures mirror the fixed native signatures enforced in check.c so hover never drifts from
// what the type checker accepts.
typedef struct {
    const char *name;
    const char *sig;
    const char *doc;
} DocCard;

// Both tables are generated from the single source of truth so hover never drifts from the
// lexer, the type checker, or the editor grammar (see include/vocab.def, OFI-033). A primitive's
// hover signature is simply its own name.
static const DocCard g_builtin_docs[] = {
    #define EMBER_BUILTIN(name, sig, doc) { name, sig, doc },
    #include "vocab.def"
};

static const DocCard g_type_docs[] = {
    #define EMBER_PRIM(name, doc) { name, name, doc },
    #include "vocab.def"
};

// lookup_card scans a DocCard table for `name`, returning the matching card or NULL.
static const DocCard *lookup_card(const DocCard *table, size_t n, const char *name) {
    for (size_t i = 0; i < n; i++) {
        if (strcmp(table[i].name, name) == 0) {
            return &table[i];
        }
    }
    return NULL;
}

// keyword_doc returns a one-line gloss for a keyword token, or NULL if `t` is not a keyword.
// The gloss table is generated from the single source of truth (include/vocab.def, OFI-033).
static const char *keyword_doc(TokenType t) {
    switch (t) {
        #define EMBER_KEYWORD(tok, word, cat, gloss) case tok: return gloss;
        #include "vocab.def"
        default:             return NULL;
    }
}

// hover_markdown writes the hover card for the token under the cursor into `val` and returns 1, or
// returns 0 if there is nothing to say. It resolves, in order: a user declaration of that name, a
// built-in function, a primitive type, then a keyword gloss.
static int hover_markdown(const Token *t, Parsed *ps, JsonBuf *val) {
    if (t->type == TOK_IDENT) {
        char name[256];
        copy_tok(t, name, sizeof name);
        const Decl *decl = find_decl(&ps->prog, name);
        if (decl != NULL) {
            JsonBuf detail;
            json_buf_init(&detail);
            decl_detail(decl, &detail);
            json_buf_puts(val, "```ember\n");
            json_buf_puts(val, detail.buf != NULL ? detail.buf : "");
            json_buf_puts(val, "\n```");
            // The author's `///` doc comment, beneath the signature — the same prose
            // `--emit=docs` renders, so the editor card and the doc page never drift.
            if (decl->doc != NULL && decl->doc[0] != '\0') {
                json_buf_puts(val, "\n\n");
                json_buf_puts(val, decl->doc);
            }
            json_buf_free(&detail);
            return 1;
        }
        const DocCard *card = lookup_card(g_builtin_docs,
                                          sizeof g_builtin_docs / sizeof g_builtin_docs[0], name);
        if (card == NULL) {
            card = lookup_card(g_type_docs,
                               sizeof g_type_docs / sizeof g_type_docs[0], name);
        }
        if (card != NULL) {
            json_buf_puts(val, "```ember\n");
            json_buf_puts(val, card->sig);
            json_buf_puts(val, "\n```\n\n");
            json_buf_puts(val, card->doc);
            return 1;
        }
        return 0;
    }
    const char *kw = keyword_doc(t->type);
    if (kw != NULL) {
        json_buf_puts(val, kw);
        return 1;
    }
    return 0;
}





// sem_kind_label returns the TypeScript/clangd-style prefix for a hover card's first
// line ("(parameter) ", "(function) ", …). A plain local needs none — its let/var is
// the tag — so SK_LOCAL/SK_NONE return "".
static const char *sem_kind_label(SemKind k) {
    switch (k) {
        case SK_PARAM:    return "(parameter) ";
        case SK_FIELD:    return "(field) ";
        case SK_METHOD:   return "(method) ";
        case SK_FUNCTION: return "(function) ";
        case SK_TYPE:     return "(type) ";
        case SK_VARIANT:  return "(variant) ";
        case SK_CONSTANT: return "(constant) ";
        case SK_MODULE:   return "(module) ";
        case SK_BUILTIN:  return "(builtin) ";
        default:          return "";
    }
}




// path_basename returns the file-name tail of a path (after the last '/'), or the
// whole string when there is no slash.
static const char *path_basename(const char *p) {
    const char *slash = strrchr(p, '/');
    return slash != NULL ? slash + 1 : p;
}




// render_sem_card writes a rich hover card (markdown) for a semantic-index entry into
// `val`: a kind-prefixed signature in an ```ember fence (with a constant's value and a
// field's byte layout folded in), the symbol's `///` doc, then a "scope · declared in
// file:line" provenance line — the clangd HoverInfo model (LSP_ROADMAP rich-hover campaign).
static void render_sem_card(const SemEntry *se, JsonBuf *val) {
    json_buf_puts(val, "```ember\n");
    json_buf_puts(val, sem_kind_label(se->kind));
    json_buf_puts(val, se->detail != NULL ? se->detail
                                          : (se->type != NULL ? se->type : "?"));
    if (se->value != NULL) {
        json_buf_puts(val, " = ");
        json_buf_puts(val, se->value);
    }
    if (se->byte_offset >= 0) {
        json_buf_puts(val, "  // offset ");
        json_buf_put_int(val, se->byte_offset);
        json_buf_puts(val, ", size ");
        json_buf_put_int(val, se->byte_size);
    }
    json_buf_puts(val, "\n```");
    if (se->doc != NULL && se->doc[0] != '\0') {
        json_buf_puts(val, "\n\n");
        json_buf_puts(val, se->doc);
    }
    // Scope ("module ui" / "in Point") + where it was declared (file:line). Karl's
    // explicit ask: the hover should teach where a value comes from.
    char scope[80] = "";
    if (se->container != NULL && se->kind != SK_MODULE) {
        const char *kw = (se->kind == SK_FIELD || se->kind == SK_METHOD) ? "in "
                       : (se->kind == SK_VARIANT)                        ? "of "
                       :                                                   "module ";
        snprintf(scope, sizeof scope, "%s%s", kw, se->container);
    }
    int has_decl = se->def_line > 0;
    if (scope[0] != '\0' || has_decl) {
        json_buf_puts(val, "\n\n*");
        int wrote = 0;
        if (scope[0] != '\0') {
            json_buf_puts(val, scope);
            wrote = 1;
        }
        if (has_decl) {
            if (wrote) {
                json_buf_puts(val, " · ");
            }
            if (se->def_file != NULL) {
                json_buf_puts(val, "declared in ");
                json_buf_puts(val, path_basename(se->def_file));
                json_buf_putc(val, ':');
                json_buf_put_int(val, se->def_line);
            } else {
                json_buf_puts(val, "declared at line ");
                json_buf_put_int(val, se->def_line);
            }
        }
        json_buf_puts(val, "*");
    }
}




static void handle_hover(const JsonValue *id, const JsonValue *params) {
    Doc *d = doc_for_params(params);
    if (d == NULL) {
        respond(id, "null");
        return;
    }
    Parsed ps;
    parse_doc(d, &ps);
    const JsonValue *pos = json_get(params, "position");
    int line0 = (int)json_as_num(json_get(pos, "line"));
    int char0 = (int)json_as_num(json_get(pos, "character"));
    char0 = char_to_byte(d->text, line0, char0);   // client encoding -> byte column for matching
    const Token *t = token_at(&ps.toks, line0, char0);
    JsonBuf val;
    json_buf_init(&val);
    // A local or parameter under the cursor is answered from the SEMANTIC INDEX (the
    // checker's inferred type), which takes precedence over a same-named top-level decl so a
    // shadowing binding hovers correctly. Top-level decls, builtins, and keywords fall through
    // to the AST/vocab path below.
    int shown = 0;
    if (t != NULL && t->type == TOK_IDENT) {
        SemanticIndex ix;
        doc_build_index(d, &ix);
        const SemEntry *se = semindex_lookup(&ix, line0 + 1, char0 + 1);
        if (se != NULL) {
            render_sem_card(se, &val);
            shown = 1;
        }
        semindex_free(&ix);
    }
    if (!shown && (t == NULL || !hover_markdown(t, &ps, &val))) {
        respond(id, "null");
        json_buf_free(&val);
        parsed_free(&ps);
        return;
    }
    JsonBuf res;
    json_buf_init(&res);
    json_buf_puts(&res, "{\"contents\":{\"kind\":\"markdown\",\"value\":");
    json_buf_put_str(&res, val.buf != NULL ? val.buf : "");
    json_buf_puts(&res, "}}");
    respond(id, res.buf);
    json_buf_free(&res);
    json_buf_free(&val);
    parsed_free(&ps);
}





static void handle_definition(const JsonValue *id, const JsonValue *params) {
    Doc *d = doc_for_params(params);
    if (d == NULL) {
        respond(id, "null");
        return;
    }
    // A local or parameter resolves to its declaration via the semantic index (scope-aware),
    // ahead of the top-level-name path so a shadowing binding jumps to the right place.
    const JsonValue *pos = json_get(params, "position");
    int line0 = (int)json_as_num(json_get(pos, "line"));
    int char0 = (int)json_as_num(json_get(pos, "character"));
    char0 = char_to_byte(d->text, line0, char0);   // client encoding -> byte column for matching
    SemanticIndex ix;
    doc_build_index(d, &ix);
    const SemEntry *se = semindex_lookup(&ix, line0 + 1, char0 + 1);
    if (se != NULL && se->def_line > 0) {
        // A cross-module symbol (its def_file is set) jumps into the imported file; otherwise
        // the definition is in the document being edited (A4).
        char       *xuri    = se->def_file != NULL ? path_to_uri(se->def_file) : NULL;
        const char *deftext = d->text;                  // same-file target: convert against the doc
        if (xuri != NULL) {
            Doc *xd = doc_find(xuri);                    // the imported file, when it is also open
            deftext = xd != NULL ? xd->text : NULL;      // NULL => identity (decl lines are ASCII)
        }
        JsonBuf res;
        json_buf_init(&res);
        json_buf_puts(&res, "{\"uri\":");
        json_buf_put_str(&res, xuri != NULL ? xuri : d->uri);
        json_buf_puts(&res, ",\"range\":");
        put_range_obj(&res, deftext, se->def_line, se->def_col, 1);
        json_buf_putc(&res, '}');
        respond(id, res.buf);
        json_buf_free(&res);
        free(xuri);
        semindex_free(&ix);
        return;
    }
    semindex_free(&ix);

    Parsed ps;
    const Decl *decl = decl_under_cursor(d, params, &ps);
    if (decl == NULL) {
        respond(id, "null");
        parsed_free(&ps);
        return;
    }
    int nlen = (int)strlen(decl_name(decl));
    JsonBuf res;
    json_buf_init(&res);
    json_buf_puts(&res, "{\"uri\":");
    json_buf_put_str(&res, d->uri);
    json_buf_puts(&res, ",\"range\":");
    put_range_obj(&res, d->text, decl->line, decl->col, nlen);
    json_buf_putc(&res, '}');
    respond(id, res.buf);
    json_buf_free(&res);
    parsed_free(&ps);
}





// put_member appends one member completion item: a label, an LSP kind, an `ember`-fenced detail,
// and (when present) the member's `///` documentation.
static void put_member(JsonBuf *b, int *first, const char *label, int kind,
                       const char *detail, const char *doc) {
    if (!*first) { json_buf_putc(b, ','); }
    *first = 0;
    json_buf_puts(b, "{\"label\":");
    json_buf_put_str(b, label);
    json_buf_puts(b, ",\"kind\":");
    json_buf_put_int(b, kind);
    if (detail != NULL) {
        json_buf_puts(b, ",\"detail\":");
        json_buf_put_str(b, detail);
    }
    if (doc != NULL && doc[0] != '\0') {
        json_buf_puts(b, ",\"documentation\":{\"kind\":\"markdown\",\"value\":");
        json_buf_put_str(b, doc);
        json_buf_putc(b, '}');
    }
    json_buf_putc(b, '}');
}




// complete_members answers a member-access completion (`receiver.`): it resolves the receiver's
// type from the semantic index, finds that type's declaration, and offers its fields/methods (a
// struct) or variants (an enum). It returns 1 whenever the cursor is in a `name.` context — even
// if the type can't be resolved (then an empty list) — so a member completion NEVER falls back to
// the global symbol list, which is what the advertised `.` trigger used to do wrongly.
static int complete_members(const JsonValue *id, Doc *d, const JsonValue *params) {
    const JsonValue *pos = json_get(params, "position");
    int line0 = (int)json_as_num(json_get(pos, "line"));
    int char0 = (int)json_as_num(json_get(pos, "character"));
    char0 = char_to_byte(d->text, line0, char0);   // client encoding -> byte column for matching
    Parsed ps;
    parse_doc(d, &ps);
    const Token *recv = member_receiver(&ps.toks, line0, char0);
    if (recv == NULL) {
        parsed_free(&ps);
        return 0;                              // not a member context — let the caller do globals
    }
    // The receiver's type name, from the checker's index, with any generic arguments stripped
    // ("Box<int>" -> "Box") so it matches the type declaration.
    char tname[128];
    tname[0] = '\0';
    SemanticIndex ix;
    doc_build_index(d, &ix);
    const SemEntry *se = semindex_lookup(&ix, recv->line, recv->col);
    if (se != NULL && se->type != NULL) {
        size_t n = 0;
        for (const char *p = se->type; *p != '\0' && *p != '<' && n < sizeof tname - 1; p++) {
            tname[n++] = *p;
        }
        tname[n] = '\0';
    }
    semindex_free(&ix);

    JsonBuf res;
    json_buf_init(&res);
    json_buf_puts(&res, "{\"isIncomplete\":false,\"items\":[");
    int first = 1;
    const Decl *decl = tname[0] != '\0' ? find_decl(&ps.prog, tname) : NULL;
    if (decl != NULL && decl->kind == DECL_STRUCT) {
        for (size_t i = 0; i < decl->as.struct_.field_count; i++) {
            const Field *f = &decl->as.struct_.fields[i];
            JsonBuf det;
            json_buf_init(&det);
            json_buf_puts(&det, f->name);
            json_buf_puts(&det, ": ");
            type_str(f->type, &det);
            put_member(&res, &first, f->name, 5 /*Field*/, det.buf, f->doc);   // CompletionItemKind.Field
            json_buf_free(&det);
        }
        for (size_t i = 0; i < decl->as.struct_.method_count; i++) {
            const FnDecl *m = &decl->as.struct_.methods[i];
            JsonBuf det;
            json_buf_init(&det);
            fn_sig(m, &det);
            put_member(&res, &first, m->name, 2 /*Method*/, det.buf, m->doc);
            json_buf_free(&det);
        }
    } else if (decl != NULL && decl->kind == DECL_ENUM) {
        for (size_t i = 0; i < decl->as.enum_.variant_count; i++) {
            const Variant *v = &decl->as.enum_.variants[i];
            put_member(&res, &first, v->name, 20 /*EnumMember*/, NULL, v->doc);
        }
    }
    json_buf_puts(&res, "]}");
    respond(id, res.buf);
    json_buf_free(&res);
    parsed_free(&ps);
    return 1;
}




static void handle_completion(const JsonValue *id, const JsonValue *params) {
    // A member access (`receiver.`) is answered from the receiver's type (semantic index → type
    // declaration); only outside that context do we offer the global symbols + keywords.
    // Generated from the single source of truth (include/vocab.def, OFI-033).
    static const char *keywords[] = {
        #define EMBER_KEYWORD(tok, word, cat, gloss) word,
        #include "vocab.def"
        NULL
    };
    Doc *d = doc_for_params(params);
    if (d != NULL && complete_members(id, d, params)) {
        return;                                // handled as a `receiver.` member completion
    }
    JsonBuf res;
    json_buf_init(&res);
    json_buf_puts(&res, "{\"isIncomplete\":false,\"items\":[");
    int first = 1;
    if (d != NULL) {
        Parsed ps;
        parse_doc(d, &ps);
        for (size_t i = 0; i < ps.prog.count; i++) {
            const Decl *dc = ps.prog.decls[i];
            const char *n  = decl_name(dc);
            if (n == NULL) {
                continue;
            }
            if (!first) { json_buf_putc(&res, ','); }
            first = 0;
            json_buf_puts(&res, "{\"label\":");
            json_buf_put_str(&res, n);
            json_buf_puts(&res, ",\"kind\":");
            json_buf_put_int(&res, completion_kind(dc->kind));
            json_buf_puts(&res, ",\"detail\":");
            JsonBuf det;
            json_buf_init(&det);
            decl_detail(dc, &det);
            json_buf_put_str(&res, det.buf != NULL ? det.buf : "");
            json_buf_free(&det);
            if (dc->doc != NULL && dc->doc[0] != '\0') {
                json_buf_puts(&res, ",\"documentation\":{\"kind\":\"markdown\",\"value\":");
                json_buf_put_str(&res, dc->doc);
                json_buf_putc(&res, '}');
            }
            json_buf_putc(&res, '}');
        }
        parsed_free(&ps);
    }
    for (int k = 0; keywords[k] != NULL; k++) {
        if (!first) { json_buf_putc(&res, ','); }
        first = 0;
        json_buf_puts(&res, "{\"label\":");
        json_buf_put_str(&res, keywords[k]);
        json_buf_puts(&res, ",\"kind\":14}");   // CompletionItemKind.Keyword
    }
    json_buf_puts(&res, "]}");
    respond(id, res.buf);
    json_buf_free(&res);
}





// put_symbol_head appends a DocumentSymbol's opening fields (no closing brace, no children).
// `text` is the document source, threaded to put_range_obj so the ranges respect the negotiated
// position encoding.
static void put_symbol_head(JsonBuf *b, const char *text, const char *name, int kind,
                            int line, int col, int len) {
    json_buf_puts(b, "{\"name\":");
    json_buf_put_str(b, name);
    json_buf_puts(b, ",\"kind\":");
    json_buf_put_int(b, kind);
    json_buf_puts(b, ",\"range\":");
    put_range_obj(b, text, line, col, len);
    json_buf_puts(b, ",\"selectionRange\":");
    put_range_obj(b, text, line, col, len);
}





static void handle_document_symbol(const JsonValue *id, const JsonValue *params) {
    Doc *d = doc_for_params(params);
    JsonBuf res;
    json_buf_init(&res);
    json_buf_putc(&res, '[');
    if (d != NULL) {
        Parsed ps;
        parse_doc(d, &ps);
        int first = 1;
        for (size_t i = 0; i < ps.prog.count; i++) {
            const Decl *dc = ps.prog.decls[i];
            const char *n  = decl_name(dc);
            if (n == NULL) {
                continue;
            }
            if (!first) { json_buf_putc(&res, ','); }
            first = 0;
            put_symbol_head(&res, d->text, n, symbol_kind(dc->kind), dc->line, dc->col,
                            (int)strlen(n));
            if (dc->kind == DECL_STRUCT) {
                json_buf_puts(&res, ",\"children\":[");
                int c0 = 1;
                for (size_t f = 0; f < dc->as.struct_.field_count; f++) {
                    const Field *fl = &dc->as.struct_.fields[f];
                    if (!c0) { json_buf_putc(&res, ','); }
                    c0 = 0;
                    put_symbol_head(&res, d->text, fl->name, 8, dc->line, dc->col,
                                    (int)strlen(fl->name));
                    json_buf_putc(&res, '}');     // Field
                }
                for (size_t m = 0; m < dc->as.struct_.method_count; m++) {
                    const FnDecl *me = &dc->as.struct_.methods[m];
                    if (!c0) { json_buf_putc(&res, ','); }
                    c0 = 0;
                    put_symbol_head(&res, d->text, me->name, 6, me->line, me->col,
                                    (int)strlen(me->name));
                    json_buf_putc(&res, '}');     // Method
                }
                json_buf_puts(&res, "]}");
            } else if (dc->kind == DECL_ENUM) {
                json_buf_puts(&res, ",\"children\":[");
                for (size_t v = 0; v < dc->as.enum_.variant_count; v++) {
                    const Variant *va = &dc->as.enum_.variants[v];
                    if (v > 0) { json_buf_putc(&res, ','); }
                    put_symbol_head(&res, d->text, va->name, 22, dc->line, dc->col,
                                    (int)strlen(va->name));
                    json_buf_putc(&res, '}');     // EnumMember
                }
                json_buf_puts(&res, "]}");
            } else if (dc->kind == DECL_INTERFACE) {
                json_buf_puts(&res, ",\"children\":[");
                for (size_t m = 0; m < dc->as.interface.method_count; m++) {
                    const FnDecl *me = &dc->as.interface.methods[m];
                    if (m > 0) { json_buf_putc(&res, ','); }
                    put_symbol_head(&res, d->text, me->name, 6, me->line, me->col,
                                    (int)strlen(me->name));
                    json_buf_putc(&res, '}');
                }
                json_buf_puts(&res, "]}");
            } else {
                json_buf_putc(&res, '}');
            }
        }
        parsed_free(&ps);
    }
    json_buf_putc(&res, ']');
    respond(id, res.buf);
    json_buf_free(&res);
}





// ---- semantic tokens (checker-driven highlighting) ---------------------------------------------
// The editor grammars (tree-sitter for Zed, TextMate for VS Code) colour the LEXICAL layer —
// keywords, strings, numbers, comments — but cannot tell a type from a variable from a parameter,
// because that needs resolution. Semantic tokens fill exactly that gap: every identifier the
// CHECKER resolved is re-coloured by what it actually denotes (the semantic index already holds
// the kind + span), so `Point` reads as a type, `a` as a parameter, `inner` as a property — no
// regex guessing. This matters most for Zed, whose grammar is intentionally minimal. The legend
// (tokenTypes/tokenModifiers below) MUST stay in lock-step with the one advertised in `initialize`.

// sem_token_type maps a SemKind to its index in the advertised tokenTypes legend, or -1 to skip.
static int sem_token_type(SemKind k) {
    switch (k) {
        case SK_MODULE:   return 0;   // namespace
        case SK_TYPE:     return 1;   // type
        case SK_PARAM:    return 2;   // parameter
        case SK_LOCAL:    return 3;   // variable
        case SK_CONSTANT: return 3;   // variable (+ readonly modifier)
        case SK_FIELD:    return 4;   // property
        case SK_VARIANT:  return 5;   // enumMember
        case SK_FUNCTION: return 6;   // function
        case SK_BUILTIN:  return 6;   // function (+ defaultLibrary modifier)
        case SK_METHOD:   return 7;   // method
        default:          return -1;  // SK_NONE / SK_LOCAL-less — nothing to colour
    }
}





// One resolved semantic token, in the negotiated client encoding, before delta-encoding.
typedef struct {
    int line;    // 0-based
    int start;   // 0-based column (client encoding)
    int len;     // length (client encoding)
    int type;    // index into the tokenTypes legend
    int mods;    // tokenModifiers bitset
} SemTok;

// semtok_cmp orders tokens by (line, start) — the order LSP's delta encoding requires.
static int semtok_cmp(const void *a, const void *b) {
    const SemTok *x = a;
    const SemTok *y = b;
    if (x->line != y->line) {
        return x->line - y->line;
    }
    return x->start - y->start;
}





static void handle_semantic_tokens(const JsonValue *id, const JsonValue *params) {
    Doc *d = doc_for_params(params);
    if (d == NULL) {
        respond(id, "{\"data\":[]}");
        return;
    }
    SemanticIndex ix;
    doc_build_index(d, &ix);

    // Project the index's resolved identifiers into positioned tokens (encoding-translated), then
    // sort — the checker fills the index in traversal order, not source order.
    SemTok *toks = ix.count > 0 ? malloc((size_t)ix.count * sizeof(SemTok)) : NULL;
    int n = 0;
    for (int i = 0; i < ix.count; i++) {
        const SemEntry *e    = &ix.entries[i];
        int             type = sem_token_type(e->kind);
        if (type < 0) {
            continue;
        }
        // Only THIS document's own occurrences. Indexing a file that imports modules also records
        // the imports' identifiers — with their file's line/col — which would otherwise be painted
        // onto this document (e.g. a token landing inside a comment). The main module's path is the
        // name we indexed with, so it equals d->path exactly.
        if (e->ref_file != NULL && strcmp(e->ref_file, d->path) != 0) {
            continue;
        }
        int line0 = e->line > 0 ? e->line - 1 : 0;
        int sbyte = e->col   > 0      ? e->col     - 1 : 0;
        int ebyte = e->end_col > e->col ? e->end_col - 1 : sbyte + 1;
        // Defence-in-depth: a semantic token must cover a real, word-bounded identifier. If a
        // recorded span doesn't (a position glitch), skip it rather than paint a stray colour onto
        // a comment, an operator, or part of a token.
        const char *ls   = line_start(d->text, line0);
        const char *le   = strchr(ls, '\n');
        int         llen = le != NULL ? (int)(le - ls) : (int)strlen(ls);
        if (ebyte > llen || ebyte <= sbyte) {
            continue;
        }
        int ident = sbyte == 0 || (!isalnum((unsigned char)ls[sbyte - 1]) && ls[sbyte - 1] != '_');
        for (int c = sbyte; ident && c < ebyte; c++) {
            ident = isalnum((unsigned char)ls[c]) || ls[c] == '_';
        }
        if (!ident) {
            continue;
        }
        int start = byte_to_char(d->text, line0, sbyte);
        int len   = byte_to_char(d->text, line0, ebyte) - start;
        if (len <= 0) {
            continue;
        }
        int mods = 0;
        if (e->kind == SK_CONSTANT) { mods |= 1 << 1; }   // readonly
        if (e->kind == SK_BUILTIN)  { mods |= 1 << 2; }   // defaultLibrary
        if (e->def_file == NULL && e->def_line == e->line && e->def_col == e->col) {
            mods |= 1 << 0;                                // declaration (this occurrence is the def)
        }
        toks[n++] = (SemTok){ line0, start, len, type, mods };
    }
    qsort(toks, (size_t)n, sizeof(SemTok), semtok_cmp);

    // Delta-encode: each token is [dLine, dStart, len, type, mods], deltas relative to the previous
    // token (dStart is absolute on a new line). Skip an exact-position repeat — overlapping tokens
    // confuse clients.
    JsonBuf b;
    json_buf_init(&b);
    json_buf_puts(&b, "{\"data\":[");
    int prev_line = 0;
    int prev_start = 0;
    int emitted = 0;
    for (int i = 0; i < n; i++) {
        if (i > 0 && toks[i].line == toks[i - 1].line && toks[i].start == toks[i - 1].start) {
            continue;
        }
        int dline  = toks[i].line - prev_line;
        int dstart = dline == 0 ? toks[i].start - prev_start : toks[i].start;
        if (emitted > 0) {
            json_buf_putc(&b, ',');
        }
        json_buf_put_int(&b, dline);
        json_buf_putc(&b, ',');
        json_buf_put_int(&b, dstart);
        json_buf_putc(&b, ',');
        json_buf_put_int(&b, toks[i].len);
        json_buf_putc(&b, ',');
        json_buf_put_int(&b, toks[i].type);
        json_buf_putc(&b, ',');
        json_buf_put_int(&b, toks[i].mods);
        prev_line  = toks[i].line;
        prev_start = toks[i].start;
        emitted++;
    }
    json_buf_puts(&b, "]}");
    respond(id, b.buf);
    json_buf_free(&b);
    free(toks);
    semindex_free(&ix);
}





// ---- find-references + rename (project-wide, off the semantic index) ----------------------------
// Every recorded reference carries the (def_file, def_line, def_col) of its DEFINITION, so "all
// references to a symbol" = "every occurrence sharing one definition identity". Find-references and
// rename are the same query: resolve the symbol under the cursor to its definition (the anchor),
// then sweep every project `.em` file's index for occurrences that point back to it. Rename is that
// set turned into a WorkspaceEdit. Re-indexing per request is fine at the current corpus size;
// caching is the obvious later refinement (same note as hover/diagnostics).

// is_ident reports whether `s` is a legal Ember identifier — rejected rename targets that would
// produce uncompilable source.
static int is_ident(const char *s) {
    if (s == NULL || (!isalpha((unsigned char)s[0]) && s[0] != '_')) {
        return 0;
    }
    for (const char *p = s + 1; *p != '\0'; p++) {
        if (!isalnum((unsigned char)*p) && *p != '_') {
            return 0;
        }
    }
    return 1;
}





// canon resolves `p` to a canonical absolute path in `out`, falling back to a copy when realpath
// fails — so def_file / ref_file / walked paths compare equal regardless of how they were spelled.
static void canon(const char *p, char out[PATH_MAX]) {
    if (p == NULL) {
        out[0] = '\0';
    } else if (realpath(p, out) == NULL) {
        snprintf(out, PATH_MAX, "%s", p);
    }
}





// dir_of writes the directory part of `path` into `out` (".", when there is no slash).
static void dir_of(const char *path, char out[PATH_MAX]) {
    snprintf(out, PATH_MAX, "%s", path);
    char *slash = strrchr(out, '/');
    if (slash != NULL) {
        *slash = '\0';
    } else {
        snprintf(out, PATH_MAX, ".");
    }
}





// file_text_for_path returns a fresh copy of `path`'s text, preferring an OPEN document's in-memory
// buffer (unsaved edits win) over the on-disk copy. NULL if unreadable. Caller frees.
static char *file_text_for_path(const char *path) {
    char want[PATH_MAX];
    canon(path, want);
    for (int i = 0; i < g_doc_count; i++) {
        char have[PATH_MAX];
        canon(g_docs[i].path, have);
        if (strcmp(have, want) == 0) {
            return strdup(g_docs[i].text != NULL ? g_docs[i].text : "");
        }
    }
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) {
        fclose(f);
        return NULL;
    }
    char  *buf = malloc((size_t)sz + 1);
    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[got] = '\0';
    return buf;
}





// walk_em recursively collects `.em` file paths under `dir`, skipping hidden entries and common
// build directories, bounded so a pathological tree can't run away.
static void walk_em(const char *dir, char ***arr, int *n, int *cap) {
    if (*n >= 4000) {
        return;
    }
    DIR *d = opendir(dir);
    if (d == NULL) {
        return;
    }
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        const char *nm = ent->d_name;
        if (nm[0] == '.') {
            continue;                            // ., .., and hidden dirs (.git, .ember, …)
        }
        if (strcmp(nm, "target") == 0 || strcmp(nm, "node_modules") == 0 ||
            strcmp(nm, "build") == 0 || strcmp(nm, "dist") == 0) {
            continue;
        }
        char path[PATH_MAX];
        snprintf(path, sizeof path, "%s/%s", dir, nm);
        struct stat st;
        if (stat(path, &st) != 0) {
            continue;
        }
        if (S_ISDIR(st.st_mode)) {
            walk_em(path, arr, n, cap);
        } else {
            size_t l = strlen(nm);
            if (l > 3 && strcmp(nm + l - 3, ".em") == 0) {
                if (*n == *cap) {
                    *cap = *cap ? *cap * 2 : 64;
                    *arr = realloc(*arr, (size_t)*cap * sizeof(char *));
                }
                (*arr)[(*n)++] = strdup(path);
            }
        }
    }
    closedir(d);
}





// free_str_array frees a string array built by walk_em.
static void free_str_array(char **arr, int n) {
    for (int i = 0; i < n; i++) {
        free(arr[i]);
    }
    free(arr);
}





// One resolved reference location, encoding-translated and ready to emit.
typedef struct {
    char *path;     // file the occurrence is in (NULL once consumed by rename's grouping)
    int   line;     // 0-based
    int   start;    // 0-based start column (client encoding)
    int   end;      // 0-based end column (client encoding)
} RefLoc;

// refloc_add appends one occurrence (translated to the negotiated encoding, deduped) to `*arr`.
static void refloc_add(RefLoc **arr, int *n, int *cap, const char *path, const char *text,
                       int line1, int col1, int end_col1) {
    int line0 = line1 > 0 ? line1 - 1 : 0;
    int sbyte = col1 > 0 ? col1 - 1 : 0;
    int ebyte = end_col1 > col1 ? end_col1 - 1 : sbyte + 1;
    int start = byte_to_char(text, line0, sbyte);
    int end   = byte_to_char(text, line0, ebyte);
    for (int i = 0; i < *n; i++) {
        if ((*arr)[i].line == line0 && (*arr)[i].start == start &&
            (*arr)[i].path != NULL && strcmp((*arr)[i].path, path) == 0) {
            return;                              // already have this exact span
        }
    }
    if (*n == *cap) {
        *cap = *cap ? *cap * 2 : 32;
        *arr = realloc(*arr, (size_t)*cap * sizeof(RefLoc));
    }
    (*arr)[*n].path  = strdup(path);
    (*arr)[*n].line  = line0;
    (*arr)[*n].start = start;
    (*arr)[*n].end   = end;
    (*n)++;
}





// span_text copies the identifier spanning 1-based (line, col)..end_col from `text` into `buf`,
// returning 0 if the span falls outside its line. Used to read a reference's spelling for matching.
static int span_text(const char *text, int line1, int col1, int end_col1, char *buf, size_t cap) {
    const char *ls   = line_start(text, line1 > 0 ? line1 - 1 : 0);
    const char *le   = strchr(ls, '\n');
    size_t      llen = le != NULL ? (size_t)(le - ls) : strlen(ls);
    int         b    = col1 > 0 ? col1 - 1 : 0;
    int         e    = end_col1 > col1 ? end_col1 - 1 : b + 1;
    if (e <= b || (size_t)e > llen) {
        return 0;
    }
    size_t nlen = (size_t)(e - b);
    if (nlen >= cap) {
        nlen = cap - 1;
    }
    memcpy(buf, ls + b, nlen);
    buf[nlen] = '\0';
    return 1;
}





// find_name_col returns the 1-based column of the first WHOLE-WORD occurrence of `name` on 1-based
// `line1` of `text`, or 0 if absent — used to locate a declaration's name on its definition line.
static int find_name_col(const char *text, int line1, const char *name) {
    const char *ls   = line_start(text, line1 > 0 ? line1 - 1 : 0);
    const char *le   = strchr(ls, '\n');
    size_t      llen = le != NULL ? (size_t)(le - ls) : strlen(ls);
    size_t      nl   = strlen(name);
    for (size_t i = 0; nl > 0 && i + nl <= llen; i++) {
        if (strncmp(ls + i, name, nl) != 0) {
            continue;
        }
        int before_ok = i == 0 || (!isalnum((unsigned char)ls[i - 1]) && ls[i - 1] != '_');
        int after_ok  = i + nl == llen || (!isalnum((unsigned char)ls[i + nl]) && ls[i + nl] != '_');
        if (before_ok && after_ok) {
            return (int)i + 1;
        }
    }
    return 0;
}





// collect_references returns every occurrence of the symbol whose DEFINITION is on line `anchor_line`
// of `anchor_path` and spells `name`, across the workspace, plus the declaration itself (located by a
// whole-word search so a coarse definition column can never edit the wrong span). Caller frees each
// `.path` then the array; *out_n is the count.
static RefLoc *collect_references(const char *anchor_path, int anchor_line,
                                  const char *name, int *out_n) {
    RefLoc *locs = NULL;
    int     n    = 0;
    int     cap  = 0;

    char anchor_canon[PATH_MAX];
    canon(anchor_path, anchor_canon);

    char root[PATH_MAX];
    if (g_root_path != NULL) {
        snprintf(root, sizeof root, "%s", g_root_path);
    } else {
        dir_of(anchor_path, root);
    }
    char **files = NULL;
    int    fc    = 0;
    int    fcap  = 0;
    walk_em(root, &files, &fc, &fcap);

    for (int fi = 0; fi < fc; fi++) {
        char *text = file_text_for_path(files[fi]);
        if (text == NULL) {
            continue;
        }
        char file_canon[PATH_MAX];
        canon(files[fi], file_canon);

        TokenList     toks = lexer_scan(text, files[fi]);
        SemanticIndex ix;
        semindex_init(&ix);
        diag_reset();
        collect_semantic_index(&toks, files[fi], &ix);
        for (int i = 0; i < ix.count; i++) {
            const SemEntry *e = &ix.entries[i];
            // Keep only THIS file's own occurrences — indexing it also records its imports', which
            // we revisit when we scan those files directly, so this avoids cross-file double-counting.
            char rc[PATH_MAX];
            canon(e->ref_file != NULL ? e->ref_file : files[fi], rc);
            if (strcmp(rc, file_canon) != 0) {
                continue;                        // not this file's own occurrence
            }
            // A symbol is identified by (definition file, definition line, spelling). `def_col` is
            // too coarse to key on — it is usually the line start, so distinct symbols declared on
            // one line collide — so we match the occurrence's TEXT: every reference is an identifier
            // spelling the symbol's name.
            char rn[256];
            char dc[PATH_MAX];
            canon(e->def_file != NULL ? e->def_file : files[fi], dc);
            if (e->def_line == anchor_line && strcmp(dc, anchor_canon) == 0 &&
                span_text(text, e->line, e->col, e->end_col, rn, sizeof rn) &&
                strcmp(rn, name) == 0) {
                // Store the CANONICAL path so a file reached two ways (e.g. a /tmp -> /private/tmp
                // symlink) is one group, not two — and dedup works across uses and the declaration.
                refloc_add(&locs, &n, &cap, file_canon, text, e->line, e->col, e->end_col);
            }
        }
        semindex_free(&ix);
        token_list_free(&toks);
        free(text);
    }
    free_str_array(files, fc);

    // The declaration itself. def_col is unreliable, so locate the name on its definition line by a
    // whole-word search — that both finds the precise span and verifies the line really declares it
    // (no match => leave it out rather than edit the wrong place).
    char *atext = file_text_for_path(anchor_path);
    if (atext != NULL) {
        int dcol = find_name_col(atext, anchor_line, name);
        if (dcol > 0) {
            refloc_add(&locs, &n, &cap, anchor_path, atext,
                       anchor_line, dcol, dcol + (int)strlen(name));
        }
        free(atext);
    }

    diag_reset();
    *out_n = n;
    return locs;
}





// cursor_anchor resolves the identifier under the request's cursor to the DEFINITION it refers to
// (or, when the cursor is on a declaration, the declaration itself), filling anchor_path/line/col
// and the symbol `name`. Returns 0 when there is no identifier to act on.
static int cursor_anchor(Doc *d, const JsonValue *params, char anchor_path[PATH_MAX],
                         int *aline, char *name, size_t namecap) {
    const JsonValue *pos   = json_get(params, "position");
    int              line0 = (int)json_as_num(json_get(pos, "line"));
    int              char0 = (int)json_as_num(json_get(pos, "character"));
    char0 = char_to_byte(d->text, line0, char0);

    TokenList    toks = lexer_scan(d->text, d->path);
    const Token *t    = token_at(&toks, line0, char0);
    if (t == NULL || t->type != TOK_IDENT) {
        token_list_free(&toks);
        return 0;
    }
    copy_tok(t, name, namecap);
    int tline = t->line;
    int tcol  = t->col;
    token_list_free(&toks);

    SemanticIndex ix;
    doc_build_index(d, &ix);
    const SemEntry *e = semindex_lookup(&ix, tline, tcol);
    if (e != NULL && e->def_line > 0) {
        canon(e->def_file != NULL ? e->def_file : d->path, anchor_path);
        *aline = e->def_line;
    } else {
        // No covering reference → treat the cursor as sitting on the declaration itself.
        canon(d->path, anchor_path);
        *aline = tline;
    }
    semindex_free(&ix);
    return 1;
}





static void handle_references(const JsonValue *id, const JsonValue *params) {
    Doc *d = doc_for_params(params);
    char anchor_path[PATH_MAX];
    char name[256];
    int  aline = 0;
    if (d == NULL || !cursor_anchor(d, params, anchor_path, &aline, name, sizeof name)) {
        respond(id, "[]");
        return;
    }
    int     n    = 0;
    RefLoc *locs = collect_references(anchor_path, aline, name, &n);

    JsonBuf b;
    json_buf_init(&b);
    json_buf_putc(&b, '[');
    for (int i = 0; i < n; i++) {
        char *uri = path_to_uri(locs[i].path);
        if (i > 0) {
            json_buf_putc(&b, ',');
        }
        json_buf_puts(&b, "{\"uri\":");
        json_buf_put_str(&b, uri);
        json_buf_puts(&b, ",\"range\":{\"start\":{\"line\":");
        json_buf_put_int(&b, locs[i].line);
        json_buf_puts(&b, ",\"character\":");
        json_buf_put_int(&b, locs[i].start);
        json_buf_puts(&b, "},\"end\":{\"line\":");
        json_buf_put_int(&b, locs[i].line);
        json_buf_puts(&b, ",\"character\":");
        json_buf_put_int(&b, locs[i].end);
        json_buf_puts(&b, "}}}");
        free(uri);
    }
    json_buf_putc(&b, ']');
    respond(id, b.buf);
    json_buf_free(&b);

    for (int i = 0; i < n; i++) {
        free(locs[i].path);
    }
    free(locs);
}





static void handle_rename(const JsonValue *id, const JsonValue *params) {
    Doc        *d        = doc_for_params(params);
    const char *new_name = json_as_str(json_get(params, "newName"));
    char        anchor_path[PATH_MAX];
    char        name[256];
    int         aline = 0;
    if (d == NULL || !is_ident(new_name) ||
        !cursor_anchor(d, params, anchor_path, &aline, name, sizeof name)) {
        respond(id, "null");
        return;
    }
    int     n    = 0;
    RefLoc *locs = collect_references(anchor_path, aline, name, &n);
    if (n == 0) {
        free(locs);
        respond(id, "null");
        return;
    }
    // WorkspaceEdit.changes = { <uri>: [ {range, newText}, … ] }, grouped by file.
    JsonBuf b;
    json_buf_init(&b);
    json_buf_puts(&b, "{\"changes\":{");
    int files_emitted = 0;
    for (int i = 0; i < n; i++) {
        if (locs[i].path == NULL) {
            continue;                            // already emitted with an earlier file's group
        }
        char *uri = path_to_uri(locs[i].path);
        if (files_emitted > 0) {
            json_buf_putc(&b, ',');
        }
        json_buf_put_str(&b, uri);
        json_buf_puts(&b, ":[");
        int edits = 0;
        for (int j = i; j < n; j++) {
            if (locs[j].path == NULL || strcmp(locs[j].path, locs[i].path) != 0) {
                continue;
            }
            if (edits > 0) {
                json_buf_putc(&b, ',');
            }
            json_buf_puts(&b, "{\"range\":{\"start\":{\"line\":");
            json_buf_put_int(&b, locs[j].line);
            json_buf_puts(&b, ",\"character\":");
            json_buf_put_int(&b, locs[j].start);
            json_buf_puts(&b, "},\"end\":{\"line\":");
            json_buf_put_int(&b, locs[j].line);
            json_buf_puts(&b, ",\"character\":");
            json_buf_put_int(&b, locs[j].end);
            json_buf_puts(&b, "}},\"newText\":");
            json_buf_put_str(&b, new_name);
            json_buf_putc(&b, '}');
            edits++;
            if (j != i) {
                free(locs[j].path);
                locs[j].path = NULL;
            }
        }
        json_buf_putc(&b, ']');
        free(locs[i].path);
        locs[i].path = NULL;
        free(uri);
        files_emitted++;
    }
    json_buf_puts(&b, "}}");
    respond(id, b.buf);
    json_buf_free(&b);
    free(locs);
}





// ---- inlay hints (inferred-type annotations on unannotated bindings) ----------------------------
// Ember's draw is that code stays legible — to a person and to a model. An unannotated `let x = …`
// hides the inferred type; an inlay hint restores it inline (`let x: int = …`) without editing the
// source. A binding is the token pattern `let`/`var` · IDENT · `=` (an annotated one has `:` there),
// found lexically so it works mid-edit; the inferred type comes from any of the binding's USES in
// the semantic index (the binding itself is not indexed, but its uses carry the checker's type and
// point their definition back at this line — the same identity trick as references).

// inferred_type_for returns the rendered type of the local bound on `bind_line` named `name`, taken
// from one of its recorded uses in `ix`, or NULL if it has none (e.g. the binding is unused).
static const char *inferred_type_for(const SemanticIndex *ix, const char *text,
                                     int bind_line, const char *name) {
    for (int i = 0; i < ix->count; i++) {
        const SemEntry *e = &ix->entries[i];
        if (e->def_line != bind_line || e->type == NULL) {
            continue;
        }
        char rn[256];
        if (span_text(text, e->line, e->col, e->end_col, rn, sizeof rn) && strcmp(rn, name) == 0) {
            return e->type;
        }
    }
    return NULL;
}





// line_end_byte returns the byte column just past the last non-whitespace character on 0-based
// `line0` of `text` — where a trailing inlay hint (e.g. a contract's verdict) sits.
static int line_end_byte(const char *text, int line0) {
    const char *ls  = line_start(text, line0);
    const char *le  = strchr(ls, '\n');
    int         len = le != NULL ? (int)(le - ls) : (int)strlen(ls);
    while (len > 0 && (ls[len - 1] == ' ' || ls[len - 1] == '\t' || ls[len - 1] == '\r')) {
        len--;
    }
    return len;
}





static void handle_inlay_hint(const JsonValue *id, const JsonValue *params) {
    Doc *d = doc_for_params(params);
    if (d == NULL) {
        respond(id, "[]");
        return;
    }
    int              start_line = 0;
    int              end_line   = INT_MAX;
    const JsonValue *range      = json_get(params, "range");
    if (range != NULL) {
        start_line = (int)json_as_num(json_get(json_get(range, "start"), "line"));
        end_line   = (int)json_as_num(json_get(json_get(range, "end"), "line"));
    }

    TokenList     toks = lexer_scan(d->text, d->path);
    SemanticIndex ix;
    doc_build_index(d, &ix);

    JsonBuf b;
    json_buf_init(&b);
    json_buf_putc(&b, '[');
    int emitted = 0;
    for (size_t i = 0; i + 2 < toks.count; i++) {
        const Token *kw = &toks.tokens[i];
        if (kw->type != TOK_LET && kw->type != TOK_VAR) {
            continue;
        }
        const Token *nm = &toks.tokens[i + 1];
        const Token *nx = &toks.tokens[i + 2];
        if (nm->type != TOK_IDENT || nx->type != TOK_ASSIGN) {
            continue;                            // annotated (`: T`) or not a plain binding
        }
        int line0 = nm->line - 1;
        if (line0 < start_line || line0 > end_line) {
            continue;
        }
        char name[256];
        copy_tok(nm, name, sizeof name);
        const char *ty = inferred_type_for(&ix, d->text, nm->line, name);
        if (ty == NULL) {
            continue;                            // unused binding → no inferred type to show
        }
        // Place the hint right after the binding name: `let x⟨: int⟩ = …`.
        int after = byte_to_char(d->text, line0, (nm->col - 1) + (int)nm->length);
        if (emitted > 0) {
            json_buf_putc(&b, ',');
        }
        JsonBuf lbl;
        json_buf_init(&lbl);
        json_buf_puts(&lbl, ": ");
        json_buf_puts(&lbl, ty);
        json_buf_puts(&b, "{\"position\":{\"line\":");
        json_buf_put_int(&b, line0);
        json_buf_puts(&b, ",\"character\":");
        json_buf_put_int(&b, after);
        json_buf_puts(&b, "},\"label\":");
        json_buf_put_str(&b, lbl.buf);
        json_buf_puts(&b, ",\"kind\":1,\"paddingLeft\":false,\"paddingRight\":false}");
        json_buf_free(&lbl);
        emitted++;
    }

    // Verification verdicts: mark each `ensures` clause the PROVER statically discharged — the
    // verification-loop differentiator, surfaced inline (a "✓ proved" the model and the human both
    // see). The prover runs over the parsed functions; a clause it can't discharge is runtime-checked.
    Parsed ps;
    parse_doc(d, &ps);
    for (size_t fi = 0; fi < ps.prog.count; fi++) {
        const Decl *dc = ps.prog.decls[fi];
        if (dc->kind != DECL_FN || dc->as.fn.ensures_count == 0) {
            continue;
        }
        const FnDecl *fn = &dc->as.fn;
        int *verdicts = malloc(fn->ensures_count * sizeof(int));
        prove_fn_verdicts(fn, verdicts);
        for (size_t k = 0; k < fn->ensures_count; k++) {
            int line0 = fn->ensures_clauses[k]->line - 1;
            if (line0 < start_line || line0 > end_line) {
                continue;
            }
            int after = byte_to_char(d->text, line0, line_end_byte(d->text, line0));
            if (emitted > 0) {
                json_buf_putc(&b, ',');
            }
            json_buf_puts(&b, "{\"position\":{\"line\":");
            json_buf_put_int(&b, line0);
            json_buf_puts(&b, ",\"character\":");
            json_buf_put_int(&b, after);
            json_buf_puts(&b, "},\"label\":");
            json_buf_put_str(&b, verdicts[k] ? "✓ proved" : "○ runtime-checked");
            json_buf_puts(&b, ",\"paddingLeft\":true,\"paddingRight\":false}");
            emitted++;
        }
        free(verdicts);
    }
    parsed_free(&ps);

    json_buf_putc(&b, ']');
    respond(id, b.buf);
    json_buf_free(&b);
    token_list_free(&toks);
    semindex_free(&ix);
}





// ---- signature help (the parameter popup while typing a call) -----------------------------------
// Inside `foo(a, |b)` the editor wants foo's signature with the current parameter highlighted. The
// call context is found lexically (works mid-edit): scan left from the cursor, tracking bracket
// depth, to the enclosing `(` — the token before it is the callee, and the top-level commas between
// it and the cursor are the active-parameter index. A free function renders with per-parameter
// labels (so the client highlights the active one); methods/builtins show the signature label.

static void handle_signature_help(const JsonValue *id, const JsonValue *params) {
    Doc *d = doc_for_params(params);
    if (d == NULL) {
        respond(id, "null");
        return;
    }
    const JsonValue *pos   = json_get(params, "position");
    int              line0 = (int)json_as_num(json_get(pos, "line"));
    int              char0 = (int)json_as_num(json_get(pos, "character"));
    char0 = char_to_byte(d->text, line0, char0);
    int eline = line0 + 1;
    int ecol  = char0 + 1;

    TokenList toks = lexer_scan(d->text, d->path);
    int       start = -1;
    for (size_t j = 0; j < toks.count; j++) {
        const Token *t = &toks.tokens[j];
        if (t->line > eline || (t->line == eline && t->col >= ecol)) {
            break;                               // tokens are ordered; this one is at/after the cursor
        }
        start = (int)j;
    }
    // Walk left to the enclosing '(' (bracket-depth aware), counting top-level commas on the way.
    int depth    = 0;
    int commas   = 0;
    int open_idx = -1;
    for (int j = start; j >= 0; j--) {
        TokenType tt = toks.tokens[j].type;
        if (tt == TOK_RPAREN || tt == TOK_RBRACKET || tt == TOK_RBRACE) {
            depth++;
        } else if (tt == TOK_LPAREN) {
            if (depth == 0) { open_idx = j; break; }
            depth--;
        } else if (tt == TOK_LBRACKET || tt == TOK_LBRACE) {
            if (depth == 0) { break; }           // cursor is inside [...] / {...}, not a call
            depth--;
        } else if (tt == TOK_COMMA && depth == 0) {
            commas++;
        }
    }
    if (open_idx < 1 || toks.tokens[open_idx - 1].type != TOK_IDENT) {
        respond(id, "null");
        token_list_free(&toks);
        return;
    }
    const Token *callee    = &toks.tokens[open_idx - 1];
    int          is_member = open_idx >= 2 && toks.tokens[open_idx - 2].type == TOK_DOT;
    char         cname[256];
    copy_tok(callee, cname, sizeof cname);

    JsonBuf b;
    json_buf_init(&b);
    int ok = 0;

    if (is_member) {
        // A method / qualified call: take the rendered signature from the semantic index (no
        // per-parameter breakdown, so no active-parameter highlight, but the signature is shown).
        SemanticIndex ix;
        doc_build_index(d, &ix);
        const SemEntry *e = semindex_lookup(&ix, callee->line, callee->col);
        if (e != NULL && e->detail != NULL) {
            json_buf_puts(&b, "{\"signatures\":[{\"label\":");
            json_buf_put_str(&b, e->detail);
            json_buf_puts(&b, ",\"parameters\":[]}],\"activeSignature\":0,\"activeParameter\":");
            json_buf_put_int(&b, commas);
            json_buf_putc(&b, '}');
            ok = 1;
        }
        semindex_free(&ix);
    } else {
        Parsed ps;
        parse_doc(d, &ps);
        const Decl *dc = find_decl(&ps.prog, cname);
        if (dc != NULL && dc->kind == DECL_FN) {
            const FnDecl *fn = &dc->as.fn;
            JsonBuf label;
            JsonBuf pjson;
            json_buf_init(&label);
            json_buf_init(&pjson);
            json_buf_puts(&label, "fn ");
            json_buf_puts(&label, fn->name);
            json_buf_putc(&label, '(');
            json_buf_putc(&pjson, '[');
            int user = 0;
            for (size_t k = 0; k < fn->param_count; k++) {
                const Param *p = &fn->params[k];
                JsonBuf one;
                json_buf_init(&one);
                if (p->is_self) {
                    json_buf_puts(&one, "self");
                } else {
                    json_buf_puts(&one, p->name != NULL ? p->name : "_");
                    if (p->type != NULL) {
                        json_buf_puts(&one, ": ");
                        type_str(p->type, &one);
                    }
                }
                if (k > 0) {
                    json_buf_puts(&label, ", ");
                }
                json_buf_puts(&label, one.buf != NULL ? one.buf : "");
                if (!p->is_self) {                // only user-passable params get a highlightable label
                    if (user > 0) { json_buf_putc(&pjson, ','); }
                    json_buf_puts(&pjson, "{\"label\":");
                    json_buf_put_str(&pjson, one.buf != NULL ? one.buf : "");
                    json_buf_putc(&pjson, '}');
                    user++;
                }
                json_buf_free(&one);
            }
            json_buf_putc(&label, ')');
            if (fn->return_type != NULL) {
                json_buf_puts(&label, " -> ");
                type_str(fn->return_type, &label);
            }
            json_buf_putc(&pjson, ']');
            int active = commas;
            if (user > 0 && active > user - 1) { active = user - 1; }
            if (active < 0) { active = 0; }
            json_buf_puts(&b, "{\"signatures\":[{\"label\":");
            json_buf_put_str(&b, label.buf != NULL ? label.buf : "");
            json_buf_puts(&b, ",\"parameters\":");
            json_buf_puts(&b, pjson.buf);
            if (fn->doc != NULL && fn->doc[0] != '\0') {
                json_buf_puts(&b, ",\"documentation\":{\"kind\":\"markdown\",\"value\":");
                json_buf_put_str(&b, fn->doc);
                json_buf_putc(&b, '}');
            }
            json_buf_puts(&b, "}],\"activeSignature\":0,\"activeParameter\":");
            json_buf_put_int(&b, active);
            json_buf_putc(&b, '}');
            json_buf_free(&label);
            json_buf_free(&pjson);
            ok = 1;
        } else {
            const DocCard *card = lookup_card(g_builtin_docs,
                                              sizeof g_builtin_docs / sizeof g_builtin_docs[0], cname);
            if (card != NULL) {
                json_buf_puts(&b, "{\"signatures\":[{\"label\":");
                json_buf_put_str(&b, card->sig);
                json_buf_puts(&b, ",\"parameters\":[]}],\"activeSignature\":0,\"activeParameter\":");
                json_buf_put_int(&b, commas);
                json_buf_putc(&b, '}');
                ok = 1;
            }
        }
        parsed_free(&ps);
    }

    respond(id, ok ? b.buf : "null");
    json_buf_free(&b);
    token_list_free(&toks);
}





// ---- code actions (contract authoring; the verification-loop differentiator) --------------------
// Surfaces the verification story as editable scaffolds: on a function, offer to add a `requires`
// precondition or an `ensures` postcondition. Clauses parse in any order and sit between the
// signature and the body `{`, so each action inserts a new clause line just before that brace.
// (Pairs with the prover-verdict inlay hints, which show whether a function's contracts are proved.)

// put_contract_action appends one CodeAction whose WorkspaceEdit inserts `clause` as a new contract
// line just before the body brace at 1-based (brace_line, brace_col) of `d`.
static void put_contract_action(JsonBuf *b, int *first, Doc *d, const char *uri,
                                 const char *title, const char *clause,
                                 int brace_line, int brace_col) {
    int         bl0     = brace_line - 1;
    const char *bls     = line_start(d->text, bl0);
    int         bcol    = brace_col > 0 ? brace_col - 1 : 0;          // byte col of '{'
    int         trimmed = bcol;
    while (trimmed > 0 && (bls[trimmed - 1] == ' ' || bls[trimmed - 1] == '\t')) {
        trimmed--;                                                    // skip whitespace before '{'
    }
    int start_ch = byte_to_char(d->text, bl0, trimmed);
    int end_ch   = trimmed > 0 ? byte_to_char(d->text, bl0, bcol) : start_ch;
    if (*first == 0) {
        json_buf_putc(b, ',');
    }
    *first = 0;
    json_buf_puts(b, "{\"title\":");
    json_buf_put_str(b, title);
    json_buf_puts(b, ",\"kind\":\"refactor.rewrite\",\"edit\":{\"changes\":{");
    json_buf_put_str(b, uri);
    json_buf_puts(b, ":[{\"range\":{\"start\":{\"line\":");
    json_buf_put_int(b, bl0);
    json_buf_puts(b, ",\"character\":");
    json_buf_put_int(b, start_ch);
    json_buf_puts(b, "},\"end\":{\"line\":");
    json_buf_put_int(b, bl0);
    json_buf_puts(b, ",\"character\":");
    json_buf_put_int(b, end_ch);
    json_buf_puts(b, "}},\"newText\":");
    JsonBuf nt;
    json_buf_init(&nt);
    json_buf_puts(&nt, trimmed > 0 ? "\n    " : "    ");   // break the signature line, or a fresh line
    json_buf_puts(&nt, clause);
    json_buf_putc(&nt, '\n');
    json_buf_put_str(b, nt.buf);
    json_buf_free(&nt);
    json_buf_puts(b, "}]}}}");
}





static void handle_code_action(const JsonValue *id, const JsonValue *params) {
    Doc *d = doc_for_params(params);
    if (d == NULL) {
        respond(id, "[]");
        return;
    }
    int cline = (int)json_as_num(json_get(json_get(json_get(params, "range"), "start"), "line")) + 1;

    Parsed ps;
    parse_doc(d, &ps);
    // The enclosing function: the last top-level fn declared at or before the cursor line.
    const FnDecl *fn = NULL;
    for (size_t i = 0; i < ps.prog.count; i++) {
        const Decl *dc = ps.prog.decls[i];
        if (dc->kind == DECL_FN && dc->as.fn.line <= cline) {
            fn = &dc->as.fn;
        }
    }
    // The body's opening brace — the first `{` at/after the fn keyword (contracts carry no braces).
    int brace_line = 0;
    int brace_col  = 0;
    if (fn != NULL) {
        int seen = 0;
        for (size_t i = 0; i < ps.toks.count; i++) {
            const Token *t = &ps.toks.tokens[i];
            if (!seen) {
                seen = t->type == TOK_FN && t->line == fn->line && t->col == fn->col;
                continue;
            }
            if (t->type == TOK_LBRACE) {
                brace_line = t->line;
                brace_col  = t->col;
                break;
            }
        }
    }
    if (fn == NULL || brace_line == 0) {
        respond(id, "[]");
        parsed_free(&ps);
        return;
    }
    JsonBuf b;
    json_buf_init(&b);
    json_buf_putc(&b, '[');
    int first = 1;
    put_contract_action(&b, &first, d, d->uri, "Add a `requires` precondition",
                        "requires true", brace_line, brace_col);
    put_contract_action(&b, &first, d, d->uri, "Add an `ensures` postcondition",
                        "ensures result == result", brace_line, brace_col);
    json_buf_putc(&b, ']');
    respond(id, b.buf);
    json_buf_free(&b);
    parsed_free(&ps);
}





int lsp_main(void) {
    diag_set_json(1);          // collect diagnostics programmatically instead of printing them
    int initialized = 1;
    (void)initialized;
    for (;;) {
        char *msg = read_message();
        if (msg == NULL) {
            break;             // client closed the connection
        }
        JsonValue *root = json_parse(msg);
        free(msg);
        if (root == NULL) {
            continue;
        }
        const char      *method = json_as_str(json_get(root, "method"));
        const JsonValue *id     = json_get(root, "id");
        const JsonValue *params = json_get(root, "params");
        if (method == NULL) {
            json_free(root);
            continue;          // a response, not a request — ignore
        }
        if (strcmp(method, "initialize") == 0) {
            // Negotiate positionEncoding (LSP 3.17): prefer utf-8 (our native byte offsets) when
            // the client offers it; otherwise fall back to the utf-16 default and translate
            // columns at the wire. Either way the encoding we advertise is one the client listed.
            g_pos_utf16 = !client_supports_utf8(params);
            // Capture the workspace root (workspaceFolders preferred, rootUri legacy) for
            // project-wide references/rename. Absent => callers fall back to the doc's directory.
            const char *root_uri = json_as_str(json_get(json_at(json_get(params,
                                                "workspaceFolders"), 0), "uri"));
            if (root_uri == NULL) {
                root_uri = json_as_str(json_get(params, "rootUri"));
            }
            if (root_uri != NULL) {
                free(g_root_path);
                g_root_path = uri_to_path(root_uri);
            }
            JsonBuf cap;
            json_buf_init(&cap);
            json_buf_puts(&cap, "{\"capabilities\":{\"positionEncoding\":\"");
            json_buf_puts(&cap, g_pos_utf16 ? "utf-16" : "utf-8");
            json_buf_puts(&cap, "\",\"textDocumentSync\":1,\"hoverProvider\":true,"
                                "\"definitionProvider\":true,\"documentSymbolProvider\":true,"
                                "\"completionProvider\":{\"triggerCharacters\":[\".\"]},"
                                "\"semanticTokensProvider\":{\"legend\":{"
                                "\"tokenTypes\":[\"namespace\",\"type\",\"parameter\",\"variable\","
                                "\"property\",\"enumMember\",\"function\",\"method\"],"
                                "\"tokenModifiers\":[\"declaration\",\"readonly\",\"defaultLibrary\"]},"
                                "\"full\":true},"
                                "\"referencesProvider\":true,\"renameProvider\":true,"
                                "\"inlayHintProvider\":true,"
                                "\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]},"
                                "\"codeActionProvider\":true},"
                                "\"serverInfo\":{\"name\":\"emberc-lsp\",\"version\":\"");
            json_buf_puts(&cap, EMBER_VERSION);
            json_buf_puts(&cap, "\"}}");
            respond(id, cap.buf);
            json_buf_free(&cap);
        } else if (strcmp(method, "shutdown") == 0) {
            respond(id, "null");
        } else if (strcmp(method, "exit") == 0) {
            json_free(root);
            break;
        } else if (strcmp(method, "textDocument/didOpen") == 0) {
            handle_did_open(params);
        } else if (strcmp(method, "textDocument/didChange") == 0) {
            handle_did_change(params);
        } else if (strcmp(method, "textDocument/didClose") == 0) {
            handle_did_close(params);
        } else if (strcmp(method, "textDocument/hover") == 0) {
            handle_hover(id, params);
        } else if (strcmp(method, "textDocument/definition") == 0) {
            handle_definition(id, params);
        } else if (strcmp(method, "textDocument/completion") == 0) {
            handle_completion(id, params);
        } else if (strcmp(method, "textDocument/documentSymbol") == 0) {
            handle_document_symbol(id, params);
        } else if (strcmp(method, "textDocument/semanticTokens/full") == 0) {
            handle_semantic_tokens(id, params);
        } else if (strcmp(method, "textDocument/references") == 0) {
            handle_references(id, params);
        } else if (strcmp(method, "textDocument/rename") == 0) {
            handle_rename(id, params);
        } else if (strcmp(method, "textDocument/inlayHint") == 0) {
            handle_inlay_hint(id, params);
        } else if (strcmp(method, "textDocument/signatureHelp") == 0) {
            handle_signature_help(id, params);
        } else if (strcmp(method, "textDocument/codeAction") == 0) {
            handle_code_action(id, params);
        } else if (id != NULL) {
            respond(id, "null");   // unknown request: empty result so the client never hangs
        }
        json_free(root);
    }
    for (int i = 0; i < g_doc_count; i++) {
        free(g_docs[i].uri);
        free(g_docs[i].path);
        free(g_docs[i].text);
    }
    free(g_docs);
    free(g_root_path);
    diag_reset();
    return 0;
}
