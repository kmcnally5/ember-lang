#include "cextern.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if EMBER_NET
#include <curl/curl.h>   // opt-in HTTPS via libcurl (make net) — "execute C libraries from Ember"
#endif
#if EMBER_SQLITE
#include "sqlite3.h"     // opt-in embedded SQL via the vendored SQLite amalgamation (make db)
#endif

// Pointer-leaf helpers (§5h pointers). A 'P' (opaque Ptr) leaf carries a C pointer in the int64
// slot; 'b' (buffer) and 'p' (const char*) leaves arrive as the Ember heap Value itself, which
// the wrapper dereferences. The boundary still owns no foreign memory: a buffer/string is
// BORROWED for the call only, and a Ptr's lifetime is managed explicitly in C (e.g. fclose).
#define PTR_VAL(p)  INT_VAL((int64_t)(intptr_t)(p))
#define AS_CPTR(v)  ((void *)(intptr_t)AS_INT(v))
#define AS_ARR(v)   ((ObjArray *)AS_OBJ(v))

// The C FFI registry (MANIFESTO §5h). Each entry pairs a C function's leaf-scalar signature with
// a wrapper that reads its arguments from `in` (flattened scalar leaves) and writes its result
// leaves to `out`. A wrapper that takes/returns a STRUCT reassembles a concrete C struct and
// passes/returns it BY VALUE — the system C compiler then generates the platform's aggregate
// calling convention (the C ABI), so Ember needs no hand-rolled marshalling.

typedef int (*CExternFn)(const Value *in, Value *out);

// --- libm scalar functions (sqrt/pow/abs/floor/ceil/round are already Ember natives) ----------
static int w_sin(const Value *a, Value *o)   { o[0] = FLOAT_VAL(sin(AS_FLOAT(a[0])));   return 1; }
static int w_cos(const Value *a, Value *o)   { o[0] = FLOAT_VAL(cos(AS_FLOAT(a[0])));   return 1; }
static int w_tan(const Value *a, Value *o)   { o[0] = FLOAT_VAL(tan(AS_FLOAT(a[0])));   return 1; }
static int w_asin(const Value *a, Value *o)  { o[0] = FLOAT_VAL(asin(AS_FLOAT(a[0])));  return 1; }
static int w_acos(const Value *a, Value *o)  { o[0] = FLOAT_VAL(acos(AS_FLOAT(a[0])));  return 1; }
static int w_atan(const Value *a, Value *o)  { o[0] = FLOAT_VAL(atan(AS_FLOAT(a[0])));  return 1; }
static int w_atan2(const Value *a, Value *o) { o[0] = FLOAT_VAL(atan2(AS_FLOAT(a[0]), AS_FLOAT(a[1]))); return 1; }
static int w_exp(const Value *a, Value *o)   { o[0] = FLOAT_VAL(exp(AS_FLOAT(a[0])));   return 1; }
static int w_log(const Value *a, Value *o)   { o[0] = FLOAT_VAL(log(AS_FLOAT(a[0])));   return 1; }
static int w_log2(const Value *a, Value *o)  { o[0] = FLOAT_VAL(log2(AS_FLOAT(a[0])));  return 1; }
static int w_log10(const Value *a, Value *o) { o[0] = FLOAT_VAL(log10(AS_FLOAT(a[0]))); return 1; }
static int w_sinh(const Value *a, Value *o)  { o[0] = FLOAT_VAL(sinh(AS_FLOAT(a[0])));  return 1; }
static int w_cosh(const Value *a, Value *o)  { o[0] = FLOAT_VAL(cosh(AS_FLOAT(a[0])));  return 1; }
static int w_tanh(const Value *a, Value *o)  { o[0] = FLOAT_VAL(tanh(AS_FLOAT(a[0])));  return 1; }
static int w_cbrt(const Value *a, Value *o)  { o[0] = FLOAT_VAL(cbrt(AS_FLOAT(a[0])));  return 1; }
static int w_trunc(const Value *a, Value *o) { o[0] = FLOAT_VAL(trunc(AS_FLOAT(a[0]))); return 1; }
static int w_hypot(const Value *a, Value *o) { o[0] = FLOAT_VAL(hypot(AS_FLOAT(a[0]), AS_FLOAT(a[1]))); return 1; }
static int w_fmod(const Value *a, Value *o)  { o[0] = FLOAT_VAL(fmod(AS_FLOAT(a[0]), AS_FLOAT(a[1])));  return 1; }

// --- structs BY VALUE: a small 2D-vector C library (proves the C-ABI struct boundary, 3b.6) ---
// These pass and return `CVec2` by value, so the C compiler emits the platform aggregate ABI;
// the wrappers only assemble the struct from leaf scalars and flatten the result back.
typedef struct { double x; double y; } CVec2;

static double cvec2_len(CVec2 v)            { return sqrt(v.x * v.x + v.y * v.y); }
static double cvec2_dot(CVec2 a, CVec2 b)   { return a.x * b.x + a.y * b.y; }
static CVec2  cvec2_add(CVec2 a, CVec2 b)   { return (CVec2){ a.x + b.x, a.y + b.y }; }
static CVec2  cvec2_scale(CVec2 v, double k){ return (CVec2){ v.x * k, v.y * k }; }

static int w_cvec2_len(const Value *a, Value *o) {
    CVec2 v = { AS_FLOAT(a[0]), AS_FLOAT(a[1]) };
    o[0] = FLOAT_VAL(cvec2_len(v));
    return 1;
}
static int w_cvec2_dot(const Value *a, Value *o) {
    CVec2 u = { AS_FLOAT(a[0]), AS_FLOAT(a[1]) };
    CVec2 v = { AS_FLOAT(a[2]), AS_FLOAT(a[3]) };
    o[0] = FLOAT_VAL(cvec2_dot(u, v));
    return 1;
}
static int w_cvec2_add(const Value *a, Value *o) {
    CVec2 u = { AS_FLOAT(a[0]), AS_FLOAT(a[1]) };
    CVec2 v = { AS_FLOAT(a[2]), AS_FLOAT(a[3]) };
    CVec2 r = cvec2_add(u, v);
    o[0] = FLOAT_VAL(r.x);
    o[1] = FLOAT_VAL(r.y);
    return 2;
}
static int w_cvec2_scale(const Value *a, Value *o) {
    CVec2 v = { AS_FLOAT(a[0]), AS_FLOAT(a[1]) };
    CVec2 r = cvec2_scale(v, AS_FLOAT(a[2]));
    o[0] = FLOAT_VAL(r.x);
    o[1] = FLOAT_VAL(r.y);
    return 2;
}


// --- pointers, buffers & opaque handles: a slice of libc (§5h pointers) -----------------------
// These prove the three pointer leaf kinds: 'p' (const char* from a borrowed string), 'b' (a
// borrowed packed-array buffer, read or written in place), and 'P' (an opaque FILE* handle that
// round-trips through Ember). Together they let a model bind real C: open a file, read/write its
// bytes through an Ember [u8] buffer, and close it.
static int w_strlen(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)strlen((const char *)AS_CSTRING(a[0])));
    return 1;
}
static int w_strncmp(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)strncmp(AS_CSTRING(a[0]), AS_CSTRING(a[1]), (size_t)AS_INT(a[2])));
    return 1;
}
static int w_fopen(const Value *a, Value *o) {
    o[0] = PTR_VAL(fopen(AS_CSTRING(a[0]), AS_CSTRING(a[1])));   // NULL on failure (a null Ptr)
    return 1;
}
static int w_fread(const Value *a, Value *o) {
    ObjArray *buf = AS_ARR(a[0]);                                // mut [u8] — written in place
    size_t    n   = (size_t)AS_INT(a[1]);
    FILE     *f   = (FILE *)AS_CPTR(a[2]);
    if (f == NULL) {                                            // fopen failure → null Ptr
        o[0] = INT_VAL(0);                                      // 0 bytes read, no deref
        return 1;
    }
    if (n > buf->length) {
        n = buf->length;                                        // never write past the buffer
    }
    o[0] = INT_VAL((int64_t)fread(buf->data, 1, n, f));
    return 1;
}
static int w_fwrite(const Value *a, Value *o) {
    ObjArray *buf = AS_ARR(a[0]);                                // [u8] — read only
    size_t    n   = (size_t)AS_INT(a[1]);
    FILE     *f   = (FILE *)AS_CPTR(a[2]);
    if (f == NULL) {                                            // fopen failure → null Ptr
        o[0] = INT_VAL(0);                                      // 0 bytes written, no deref
        return 1;
    }
    if (n > buf->length) {
        n = buf->length;
    }
    o[0] = INT_VAL((int64_t)fwrite(buf->data, 1, n, f));
    return 1;
}
static int w_fclose(const Value *a, Value *o) {
    FILE *f = (FILE *)AS_CPTR(a[0]);
    if (f == NULL) {                                            // fclose(NULL) is undefined
        o[0] = INT_VAL((int64_t)EOF);
        return 1;
    }
    o[0] = INT_VAL((int64_t)fclose(f));
    return 1;
}


#if EMBER_NET
// HTTPS via libcurl (opt-in: `make net` links -lcurl). The boundary owns no Ember memory: the
// url/headers/body are BORROWED const char*; the response is a fresh malloc'd char* returned in
// out[0] as a PTR_VAL — the FFI marshalling (ret_is_string) COPIES it into an Ember string and
// frees it (the §5h / OFI-043 copy-on-return rule). This is the one C library Ember binds for the
// Claude Desktop app; everything else stays in pure Ember.
struct net_membuf {
    char  *data;
    size_t len;
    size_t cap;
};


static size_t net_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    struct net_membuf *m = (struct net_membuf *)userdata;
    size_t add = size * nmemb;
    if (m->len + add + 1 > m->cap) {
        size_t newcap = m->cap ? m->cap : 16384;
        while (newcap < m->len + add + 1) {
            newcap *= 2;
        }
        char *nb = realloc(m->data, newcap);
        if (nb == NULL) {
            return 0;                       // signal an error to curl
        }
        m->data = nb;
        m->cap  = newcap;
    }
    memcpy(m->data + m->len, ptr, add);
    m->len += add;
    m->data[m->len] = '\0';
    return add;
}


// http_post(url, headers, body) -> string. `headers` is one string of header lines separated by
// '\n' (e.g. "x-api-key: …\nanthropic-version: 2023-06-01\ncontent-type: application/json"). The
// returned string is the raw response body, or a small JSON object `{"_curl_error":"…"}` if the
// transfer itself failed (so the Ember side always gets a string it can inspect).
static int w_http_post(const Value *a, Value *o) {
    const char *url     = (const char *)AS_CSTRING(a[0]);
    const char *headers = (const char *)AS_CSTRING(a[1]);
    const char *body    = (const char *)AS_CSTRING(a[2]);
    struct net_membuf m = { NULL, 0, 0 };
    CURL *curl = curl_easy_init();
    if (curl == NULL) {
        o[0] = PTR_VAL(strdup("{\"_curl_error\":\"curl_easy_init failed\"}"));
        return 1;
    }
    struct curl_slist *hdrs = NULL;
    char *hcopy = strdup(headers);                 // strtok mutates, so work on a copy
    if (hcopy != NULL) {
        for (char *line = strtok(hcopy, "\n"); line != NULL; line = strtok(NULL, "\n")) {
            if (*line != '\0') {
                hdrs = curl_slist_append(hdrs, line);
            }
        }
    }
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(body));
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, net_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &m);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "ember-claude/0.1");
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);
    CURLcode rc = curl_easy_perform(curl);
    curl_slist_free_all(hdrs);
    free(hcopy);
    curl_easy_cleanup(curl);
    if (rc != CURLE_OK) {
        free(m.data);
        const char *err = curl_easy_strerror(rc);
        size_t n = strlen(err) + 40;
        char *e = malloc(n);
        if (e != NULL) {
            snprintf(e, n, "{\"_curl_error\":\"%s\"}", err);
        }
        o[0] = PTR_VAL(e);
        return 1;
    }
    o[0] = PTR_VAL(m.data != NULL ? m.data : strdup(""));
    return 1;
}


// http_get(url, headers) -> string. Like http_post but issues a GET (no body) with short connect/total
// timeouts, so probing a model list against a down or slow server fails fast instead of hanging the
// caller. Returns the raw response body, or `{"_curl_error":"…"}` if the transfer itself failed.
static int w_http_get(const Value *a, Value *o) {
    const char *url     = (const char *)AS_CSTRING(a[0]);
    const char *headers = (const char *)AS_CSTRING(a[1]);
    struct net_membuf m = { NULL, 0, 0 };
    CURL *curl = curl_easy_init();
    if (curl == NULL) {
        o[0] = PTR_VAL(strdup("{\"_curl_error\":\"curl_easy_init failed\"}"));
        return 1;
    }
    struct curl_slist *hdrs = NULL;
    char *hcopy = strdup(headers);                 // strtok mutates, so work on a copy
    if (hcopy != NULL) {
        for (char *line = strtok(hcopy, "\n"); line != NULL; line = strtok(NULL, "\n")) {
            if (*line != '\0') {
                hdrs = curl_slist_append(hdrs, line);
            }
        }
    }
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, net_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &m);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "ember-http/0.1");
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 4L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 20L);
    CURLcode rc = curl_easy_perform(curl);
    curl_slist_free_all(hdrs);
    free(hcopy);
    curl_easy_cleanup(curl);
    if (rc != CURLE_OK) {
        free(m.data);
        const char *err = curl_easy_strerror(rc);
        size_t n = strlen(err) + 40;
        char *e = malloc(n);
        if (e != NULL) {
            snprintf(e, n, "{\"_curl_error\":\"%s\"}", err);
        }
        o[0] = PTR_VAL(e);
        return 1;
    }
    o[0] = PTR_VAL(m.data != NULL ? m.data : strdup(""));
    return 1;
}


// ---- STREAMING HTTP (the std/http transport, design of record docs/http-design.md) -------------
// A PULL stream behind an opaque Ptr handle, the fopen/fread/fclose leaf-FFI pattern (§5h): the Ember
// worker fiber owns the channel and pumps http_next, so concurrency stays 100% Ember (fibers+channels)
// and no runtime/channel mechanism leaks into C. curl_multi drives the transfer incrementally — chunks
// are delivered as the network yields them, so SSE arrives token-by-token. http_open POSTs and returns
// the handle; http_next blocks for the next body chunk ("" once the transfer ends); http_close frees it.
struct http_stream {
    CURLM             *multi;
    CURL              *easy;
    struct curl_slist *hdrs;
    char              *buf;       // chunk accumulator, reset each http_next pull
    size_t             len;
    size_t             cap;
    int                running;   // curl_multi still-running count
    int                done;      // transfer finished (EOF is sticky)
};


// hs_write_cb appends received bytes to the handle's chunk accumulator (one transfer per handle).
static size_t hs_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    struct http_stream *s = (struct http_stream *)userdata;
    size_t add = size * nmemb;
    if (s->len + add + 1 > s->cap) {
        size_t nc = s->cap ? s->cap : 8192;
        while (nc < s->len + add + 1) {
            nc *= 2;
        }
        char *nb = realloc(s->buf, nc);
        if (nb == NULL) {
            return 0;             // signal an error to curl
        }
        s->buf = nb;
        s->cap = nc;
    }
    memcpy(s->buf + s->len, ptr, add);
    s->len += add;
    s->buf[s->len] = '\0';
    return add;
}


// http_open(url, headers, body) -> Ptr. POSTs `body` with `headers` ('\n'-separated lines); returns an
// opaque stream handle (a null Ptr on setup failure). The transfer starts but does not block here.
static int w_http_open(const Value *a, Value *o) {
    const char *url     = (const char *)AS_CSTRING(a[0]);
    const char *headers = (const char *)AS_CSTRING(a[1]);
    const char *body    = (const char *)AS_CSTRING(a[2]);
    struct http_stream *s = (struct http_stream *)calloc(1, sizeof *s);
    if (s == NULL) {
        o[0] = PTR_VAL(NULL);
        return 1;
    }
    s->multi = curl_multi_init();
    s->easy  = curl_easy_init();
    if (s->multi == NULL || s->easy == NULL) {
        if (s->easy)  curl_easy_cleanup(s->easy);
        if (s->multi) curl_multi_cleanup(s->multi);
        free(s);
        o[0] = PTR_VAL(NULL);
        return 1;
    }
    char *hcopy = strdup(headers);                 // strtok mutates, so work on a copy
    if (hcopy != NULL) {
        for (char *line = strtok(hcopy, "\n"); line != NULL; line = strtok(NULL, "\n")) {
            if (*line != '\0') {
                s->hdrs = curl_slist_append(s->hdrs, line);
            }
        }
        free(hcopy);
    }
    curl_easy_setopt(s->easy, CURLOPT_URL, url);
    curl_easy_setopt(s->easy, CURLOPT_POST, 1L);
    curl_easy_setopt(s->easy, CURLOPT_COPYPOSTFIELDS, body);   // curl copies the body — no lifetime worry
    curl_easy_setopt(s->easy, CURLOPT_HTTPHEADER, s->hdrs);
    curl_easy_setopt(s->easy, CURLOPT_WRITEFUNCTION, hs_write_cb);
    curl_easy_setopt(s->easy, CURLOPT_WRITEDATA, s);
    curl_easy_setopt(s->easy, CURLOPT_USERAGENT, "ember-http/0.1");
    curl_easy_setopt(s->easy, CURLOPT_TIMEOUT, 300L);
    curl_multi_add_handle(s->multi, s->easy);
    s->running = 1;
    o[0] = PTR_VAL(s);
    return 1;
}


// http_next(h) -> string. Pumps the transfer until the next body chunk arrives, returning it; returns
// "" once the stream ends (EOF is sticky). Blocks on the calling fiber — exactly like a blocking read.
static int w_http_next(const Value *a, Value *o) {
    struct http_stream *s = (struct http_stream *)AS_CPTR(a[0]);
    if (s == NULL) {
        o[0] = PTR_VAL(strdup(""));
        return 1;
    }
    s->len = 0;                                    // fresh accumulator for this pull
    if (s->buf != NULL) {
        s->buf[0] = '\0';
    }
    while (s->len == 0 && !s->done) {
        int numfds = 0;
        curl_multi_poll(s->multi, NULL, 0, 200, &numfds);
        if (curl_multi_perform(s->multi, &s->running) != CURLM_OK) {
            break;
        }
        if (s->running == 0) {
            s->done = 1;                           // all data delivered before running hits 0
        }
    }
    if (s->len == 0) {
        o[0] = PTR_VAL(strdup(""));                // EOF / no data this pull
        return 1;
    }
    char *out = (char *)malloc(s->len + 1);        // copied into an Ember string + freed by the FFI
    if (out != NULL) {
        memcpy(out, s->buf, s->len);
        out[s->len] = '\0';
    }
    o[0] = PTR_VAL(out != NULL ? out : strdup(""));
    return 1;
}


// http_status(h) -> int. The HTTP response status code (0 until the response headers have arrived).
static int w_http_status(const Value *a, Value *o) {
    struct http_stream *s = (struct http_stream *)AS_CPTR(a[0]);
    long code = 0;
    if (s != NULL && s->easy != NULL) {
        curl_easy_getinfo(s->easy, CURLINFO_RESPONSE_CODE, &code);
    }
    o[0] = INT_VAL((int64_t)code);
    return 1;
}


// http_close(h). Frees the handle and all libcurl state. Safe on a null handle.
static int w_http_close(const Value *a, Value *o) {
    struct http_stream *s = (struct http_stream *)AS_CPTR(a[0]);
    if (s != NULL) {
        if (s->multi != NULL && s->easy != NULL) {
            curl_multi_remove_handle(s->multi, s->easy);
        }
        if (s->easy != NULL) {
            curl_easy_cleanup(s->easy);
        }
        if (s->multi != NULL) {
            curl_multi_cleanup(s->multi);
        }
        if (s->hdrs != NULL) {
            curl_slist_free_all(s->hdrs);
        }
        free(s->buf);
        free(s);
    }
    o[0] = INT_VAL(0);
    return 1;
}
#endif  // EMBER_NET


#if EMBER_SQLITE
// ---- Embedded SQL via the vendored SQLite amalgamation (the std/sqlite binding, `make db`) ------
// SQLite is the one database that fits Ember's empty-dependency-tree rule: a single public-domain
// translation unit (third_party/sqlite/sqlite3.c), no server, no system package. These wrappers are
// the leaf-FFI image of its C API — a connection (sqlite3*) and a prepared statement (sqlite3_stmt*)
// each cross as an opaque 'P' handle, which makes them LINEAR on the Ember side: the compiler proves
// every open() is closed and every prepare() is finalized, on every path (OFI-049). Text crosses the
// boundary copied-and-freed ('p' out, ret_is_string=1); a borrowed 'P' is never owned by C past the
// call. The Result-returning, `?`-friendly Ember surface is std/sqlite.em layered on top.

// sqlite_open(path) -> Ptr. Opens `path` (creating the file if absent) and returns the connection
// handle. SQLite hands back a usable handle even when open fails, so sqlite_errmsg still works; only
// an out-of-memory open yields NULL (which sqlite_errcode reports as an error below).
static int w_sqlite_open(const Value *a, Value *o) {
    sqlite3 *db = NULL;
    sqlite3_open_v2((const char *)AS_CSTRING(a[0]), &db,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    o[0] = PTR_VAL(db);
    return 1;
}

// sqlite_close(db) -> int. Closes the connection; close_v2 tolerates statements that outlive it,
// finalizing them lazily. Returns the SQLite result code. A null handle is a safe no-op.
static int w_sqlite_close(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)sqlite3_close_v2((sqlite3 *)AS_CPTR(a[0])));
    return 1;
}

// sqlite_errcode(db) -> int. The extended result code of the most recent failed call on `db`
// (SQLITE_OK == 0 means no error). std/sqlite uses this to turn a bad open()/prepare() into an Err.
static int w_sqlite_errcode(const Value *a, Value *o) {
    sqlite3 *db = (sqlite3 *)AS_CPTR(a[0]);
    o[0] = INT_VAL((int64_t)(db != NULL ? sqlite3_extended_errcode(db) : SQLITE_NOMEM));
    return 1;
}

// sqlite_errmsg(db) -> string. The English message for the most recent error on `db`, copied into
// an Ember string (ret_is_string copies the buffer in and frees the strdup).
static int w_sqlite_errmsg(const Value *a, Value *o) {
    sqlite3     *db = (sqlite3 *)AS_CPTR(a[0]);
    const char  *m  = db != NULL ? sqlite3_errmsg(db) : "null database handle";
    o[0] = PTR_VAL(strdup(m != NULL ? m : "unknown error"));
    return 1;
}

// sqlite_errstr(code) -> string. The English text for a bare result code (no handle needed) — used
// to describe a step() failure, which holds only the statement, not its connection.
static int w_sqlite_errstr(const Value *a, Value *o) {
    const char *m = sqlite3_errstr((int)AS_INT(a[0]));
    o[0] = PTR_VAL(strdup(m != NULL ? m : "unknown error"));
    return 1;
}

// sqlite_exec(db, sql) -> int. Runs one or more semicolon-separated statements that return no rows
// (DDL, INSERT/UPDATE/DELETE) in a single call, returning the SQLite result code — this is what makes
// running a whole schema script one line. The reason for a failure is read back with sqlite_errmsg.
static int w_sqlite_exec(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)sqlite3_exec((sqlite3 *)AS_CPTR(a[0]),
                                         (const char *)AS_CSTRING(a[1]), NULL, NULL, NULL));
    return 1;
}

// sqlite_prepare(db, sql) -> Ptr. Compiles the FIRST statement of `sql` into a prepared-statement
// handle, returning NULL on a compile error (the reason is then in sqlite_errmsg(db)). Only the first
// statement is compiled — multi-statement scripts go through sqlite_exec.
static int w_sqlite_prepare(const Value *a, Value *o) {
    sqlite3_stmt *st = NULL;
    sqlite3_prepare_v2((sqlite3 *)AS_CPTR(a[0]), (const char *)AS_CSTRING(a[1]), -1, &st, NULL);
    o[0] = PTR_VAL(st);
    return 1;
}

// sqlite_bind_int(stmt, idx, val) -> int. Binds a 64-bit integer to parameter `idx` (1-based).
static int w_sqlite_bind_int(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)sqlite3_bind_int64((sqlite3_stmt *)AS_CPTR(a[0]),
                                               (int)AS_INT(a[1]), AS_INT(a[2])));
    return 1;
}

// sqlite_bind_f64(stmt, idx, val) -> int. Binds a double to parameter `idx` (1-based).
static int w_sqlite_bind_f64(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)sqlite3_bind_double((sqlite3_stmt *)AS_CPTR(a[0]),
                                                (int)AS_INT(a[1]), AS_FLOAT(a[2])));
    return 1;
}

// sqlite_bind_text(stmt, idx, val) -> int. Binds a text value to parameter `idx` (1-based).
// SQLITE_TRANSIENT tells SQLite to COPY the bytes, so the borrowed Ember string need not outlive the
// call.
static int w_sqlite_bind_text(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)sqlite3_bind_text((sqlite3_stmt *)AS_CPTR(a[0]), (int)AS_INT(a[1]),
                                              (const char *)AS_CSTRING(a[2]), -1, SQLITE_TRANSIENT));
    return 1;
}

// sqlite_bind_null(stmt, idx) -> int. Binds SQL NULL to parameter `idx` (1-based).
static int w_sqlite_bind_null(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)sqlite3_bind_null((sqlite3_stmt *)AS_CPTR(a[0]), (int)AS_INT(a[1])));
    return 1;
}

// sqlite_step(stmt) -> int. Advances to the next result row, returning SQLITE_ROW (100) when a row is
// ready, SQLITE_DONE (101) when the statement has finished, or an error code. std/sqlite maps these
// onto Result<bool, string> so a `?`-driven loop reads naturally.
static int w_sqlite_step(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)sqlite3_step((sqlite3_stmt *)AS_CPTR(a[0])));
    return 1;
}

// sqlite_reset(stmt) -> int. Resets a statement to its initial state and clears its parameter
// bindings, so it can be re-bound and re-stepped (a loop of INSERTs reuses one compiled statement).
static int w_sqlite_reset(const Value *a, Value *o) {
    sqlite3_stmt *st = (sqlite3_stmt *)AS_CPTR(a[0]);
    int rc = sqlite3_reset(st);
    sqlite3_clear_bindings(st);
    o[0] = INT_VAL((int64_t)rc);
    return 1;
}

// sqlite_column_count(stmt) -> int. The number of result columns produced by the current row.
static int w_sqlite_column_count(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)sqlite3_column_count((sqlite3_stmt *)AS_CPTR(a[0])));
    return 1;
}

// sqlite_column_type(stmt, col) -> int. The storage class of column `col` (0-based) in the current
// row: 1 INTEGER, 2 FLOAT, 3 TEXT, 4 BLOB, 5 NULL (the SQLITE_* datatype constants).
static int w_sqlite_column_type(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)sqlite3_column_type((sqlite3_stmt *)AS_CPTR(a[0]), (int)AS_INT(a[1])));
    return 1;
}

// sqlite_column_int(stmt, col) -> int. Column `col` (0-based) of the current row as a 64-bit integer.
static int w_sqlite_column_int(const Value *a, Value *o) {
    o[0] = INT_VAL(sqlite3_column_int64((sqlite3_stmt *)AS_CPTR(a[0]), (int)AS_INT(a[1])));
    return 1;
}

// sqlite_column_f64(stmt, col) -> f64. Column `col` (0-based) of the current row as a double.
static int w_sqlite_column_f64(const Value *a, Value *o) {
    o[0] = FLOAT_VAL(sqlite3_column_double((sqlite3_stmt *)AS_CPTR(a[0]), (int)AS_INT(a[1])));
    return 1;
}

// sqlite_column_text(stmt, col) -> string. Column `col` (0-based) of the current row as text, copied
// into an Ember string. A NULL column comes back as "" (test sqlite_column_type for a true NULL).
static int w_sqlite_column_text(const Value *a, Value *o) {
    const unsigned char *t = sqlite3_column_text((sqlite3_stmt *)AS_CPTR(a[0]), (int)AS_INT(a[1]));
    o[0] = PTR_VAL(strdup(t != NULL ? (const char *)t : ""));
    return 1;
}

// sqlite_column_name(stmt, col) -> string. The name of result column `col` (0-based), copied into an
// Ember string — the basis for a future Map<string, _> row helper.
static int w_sqlite_column_name(const Value *a, Value *o) {
    const char *n = sqlite3_column_name((sqlite3_stmt *)AS_CPTR(a[0]), (int)AS_INT(a[1]));
    o[0] = PTR_VAL(strdup(n != NULL ? n : ""));
    return 1;
}

// sqlite_finalize(stmt) -> int. Destroys a prepared statement and releases its resources. A null
// handle is a safe no-op, so a failed prepare() can still be finalized to satisfy linearity.
static int w_sqlite_finalize(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)sqlite3_finalize((sqlite3_stmt *)AS_CPTR(a[0])));
    return 1;
}

// sqlite_changes(db) -> int. The number of rows inserted, updated, or deleted by the most recent
// statement on `db` — what exec() reports back to the caller.
static int w_sqlite_changes(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)sqlite3_changes((sqlite3 *)AS_CPTR(a[0])));
    return 1;
}

// sqlite_last_insert_rowid(db) -> int. The ROWID of the most recent successful INSERT on `db`.
static int w_sqlite_last_insert_rowid(const Value *a, Value *o) {
    o[0] = INT_VAL((int64_t)sqlite3_last_insert_rowid((sqlite3 *)AS_CPTR(a[0])));
    return 1;
}
#endif  // EMBER_SQLITE


static const CExternSig g_sigs[] = {
    { "sin",   1, { 'f' },                1, { 'f' }, 0, 0 },
    { "cos",   1, { 'f' },                1, { 'f' }, 0, 0 },
    { "tan",   1, { 'f' },                1, { 'f' }, 0, 0 },
    { "asin",  1, { 'f' },                1, { 'f' }, 0, 0 },
    { "acos",  1, { 'f' },                1, { 'f' }, 0, 0 },
    { "atan",  1, { 'f' },                1, { 'f' }, 0, 0 },
    { "atan2", 2, { 'f', 'f' },           1, { 'f' }, 0, 0 },
    { "exp",   1, { 'f' },                1, { 'f' }, 0, 0 },
    { "log",   1, { 'f' },                1, { 'f' }, 0, 0 },
    { "log2",  1, { 'f' },                1, { 'f' }, 0, 0 },
    { "log10", 1, { 'f' },                1, { 'f' }, 0, 0 },
    { "sinh",  1, { 'f' },                1, { 'f' }, 0, 0 },
    { "cosh",  1, { 'f' },                1, { 'f' }, 0, 0 },
    { "tanh",  1, { 'f' },                1, { 'f' }, 0, 0 },
    { "cbrt",  1, { 'f' },                1, { 'f' }, 0, 0 },
    { "trunc", 1, { 'f' },                1, { 'f' }, 0, 0 },
    { "hypot", 2, { 'f', 'f' },           1, { 'f' }, 0, 0 },
    { "fmod",  2, { 'f', 'f' },           1, { 'f' }, 0, 0 },
    // structs by value (a Vec2 = two f64):
    { "cvec2_len",   2, { 'f', 'f' },           1, { 'f' },      0, 0 },
    { "cvec2_dot",   4, { 'f', 'f', 'f', 'f' }, 1, { 'f' },      0, 0 },
    { "cvec2_add",   4, { 'f', 'f', 'f', 'f' }, 2, { 'f', 'f' }, 1, 0 },
    { "cvec2_scale", 3, { 'f', 'f', 'f' },      2, { 'f', 'f' }, 1, 0 },
    // pointers / buffers / opaque handles (§5h pointers):
    { "strlen",  1, { 'p' },           1, { 'i' }, 0, 0 },
    { "strncmp", 3, { 'p', 'p', 'i' }, 1, { 'i' }, 0, 0 },
    { "fopen",   2, { 'p', 'p' },      1, { 'P' }, 0, 0 },
    { "fread",   3, { 'b', 'i', 'P' }, 1, { 'i' }, 0, 0 },
    { "fwrite",  3, { 'b', 'i', 'P' }, 1, { 'i' }, 0, 0 },
    { "fclose",  1, { 'P' },           1, { 'i' }, 0, 0 },
#if EMBER_NET
    // HTTPS POST (make net): url, headers ('\n'-separated lines), body → response string.
    { "http_post", 3, { 'p', 'p', 'p' }, 1, { 'p' }, 0, 1 },
    // HTTPS GET (make net): url, headers → response string (short timeouts — probe a model list).
    { "http_get",  2, { 'p', 'p' },      1, { 'p' }, 0, 1 },
    // Streaming HTTP (the std/http transport): an opaque Ptr handle, pulled chunk by chunk.
    { "http_open",   3, { 'p', 'p', 'p' }, 1, { 'P' }, 0, 0 },
    { "http_next",   1, { 'P' },           1, { 'p' }, 0, 1 },   // returns a string chunk (copied + freed)
    { "http_status", 1, { 'P' },           1, { 'i' }, 0, 0 },
    { "http_close",  1, { 'P' },           1, { 'i' }, 0, 0 },
#endif
#if EMBER_SQLITE
    // Embedded SQL via the vendored SQLite amalgamation (make db). A connection and a statement are
    // opaque 'P' handles; text crosses copied-and-freed ('p' out, ret_is_string=1).
    { "sqlite_open",              1, { 'p' },           1, { 'P' }, 0, 0 },
    { "sqlite_close",             1, { 'P' },           1, { 'i' }, 0, 0 },
    { "sqlite_errcode",           1, { 'P' },           1, { 'i' }, 0, 0 },
    { "sqlite_errmsg",            1, { 'P' },           1, { 'p' }, 0, 1 },
    { "sqlite_errstr",            1, { 'i' },           1, { 'p' }, 0, 1 },
    { "sqlite_exec",              2, { 'P', 'p' },      1, { 'i' }, 0, 0 },
    { "sqlite_prepare",           2, { 'P', 'p' },      1, { 'P' }, 0, 0 },
    { "sqlite_bind_int",          3, { 'P', 'i', 'i' }, 1, { 'i' }, 0, 0 },
    { "sqlite_bind_f64",          3, { 'P', 'i', 'f' }, 1, { 'i' }, 0, 0 },
    { "sqlite_bind_text",         3, { 'P', 'i', 'p' }, 1, { 'i' }, 0, 0 },
    { "sqlite_bind_null",         2, { 'P', 'i' },      1, { 'i' }, 0, 0 },
    { "sqlite_step",              1, { 'P' },           1, { 'i' }, 0, 0 },
    { "sqlite_reset",             1, { 'P' },           1, { 'i' }, 0, 0 },
    { "sqlite_column_count",      1, { 'P' },           1, { 'i' }, 0, 0 },
    { "sqlite_column_type",       2, { 'P', 'i' },      1, { 'i' }, 0, 0 },
    { "sqlite_column_int",        2, { 'P', 'i' },      1, { 'i' }, 0, 0 },
    { "sqlite_column_f64",        2, { 'P', 'i' },      1, { 'f' }, 0, 0 },
    { "sqlite_column_text",       2, { 'P', 'i' },      1, { 'p' }, 0, 1 },
    { "sqlite_column_name",       2, { 'P', 'i' },      1, { 'p' }, 0, 1 },
    { "sqlite_finalize",          1, { 'P' },           1, { 'i' }, 0, 0 },
    { "sqlite_changes",           1, { 'P' },           1, { 'i' }, 0, 0 },
    { "sqlite_last_insert_rowid", 1, { 'P' },           1, { 'i' }, 0, 0 },
#endif
};


static const CExternFn g_fns[] = {
    w_sin, w_cos, w_tan, w_asin, w_acos, w_atan, w_atan2, w_exp, w_log,
    w_log2, w_log10, w_sinh, w_cosh, w_tanh, w_cbrt, w_trunc, w_hypot, w_fmod,
    w_cvec2_len, w_cvec2_dot, w_cvec2_add, w_cvec2_scale,
    w_strlen, w_strncmp, w_fopen, w_fread, w_fwrite, w_fclose,
#if EMBER_NET
    w_http_post,
    w_http_get,
    w_http_open, w_http_next, w_http_status, w_http_close,
#endif
#if EMBER_SQLITE
    w_sqlite_open, w_sqlite_close, w_sqlite_errcode, w_sqlite_errmsg, w_sqlite_errstr,
    w_sqlite_exec, w_sqlite_prepare,
    w_sqlite_bind_int, w_sqlite_bind_f64, w_sqlite_bind_text, w_sqlite_bind_null,
    w_sqlite_step, w_sqlite_reset,
    w_sqlite_column_count, w_sqlite_column_type, w_sqlite_column_int, w_sqlite_column_f64,
    w_sqlite_column_text, w_sqlite_column_name,
    w_sqlite_finalize, w_sqlite_changes, w_sqlite_last_insert_rowid,
#endif
};


static const int g_count = (int)(sizeof g_sigs / sizeof g_sigs[0]);


int cextern_lookup(const char *name) {
    for (int i = 0; i < g_count; i++) {
        if (strcmp(g_sigs[i].name, name) == 0) {
            return i;
        }
    }
    return -1;
}


const CExternSig *cextern_sig(int index) {
    return &g_sigs[index];
}


int cextern_call(int index, const Value *in, Value *out) {
    return g_fns[index](in, out);
}
