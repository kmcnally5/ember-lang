#ifndef EMBER_DIAG_H
#define EMBER_DIAG_H

#include <stdio.h>

// Diagnostics as data (MANIFESTO §3.5/§5 — "the compiler is a teacher"). Every
// compile error flows through diag_error. In the default human mode it prints
// immediately in the familiar `file:line:col: error: msg` form — byte-identical to
// before. Under `--diagnostics=json` the errors are instead collected and emitted as
// JSON Lines (diag_flush_json), so an LLM author can parse them and apply the
// suggested fix. One structured record, two renderings.
//
// A diagnostic may carry, beyond its primary message:
//   - `near`: trailing context (the parser's "near 'X'"), or NULL.
//   - `help`: a concrete suggested fix in the user's terms, or NULL.
// and an optional secondary location attached afterwards by diag_note (e.g. "value
// moved here") — the §3.1 ideal of explaining the fix, not the theory.

void diag_set_json(int on);
int  diag_json_enabled(void);

// Report one error at file:line:col. `near` and `help` are optional (NULL = absent).
// In human mode this prints now; in JSON mode it is collected for diag_flush_json.
void diag_error(const char *file, int line, int col,
                const char *msg, const char *near, const char *help);

// Attach a secondary location + label ("note") to the most recent diagnostic — e.g.
// where a moved value was moved. No-op if no diagnostic has been reported yet.
void diag_note(const char *file, int line, int col, const char *msg);

void diag_flush_json(FILE *out);   // emit all collected diagnostics as JSON Lines
void diag_reset(void);             // free collected diagnostics

// Programmatic access to the collected diagnostics (collect mode, i.e. diag_set_json(1)) — used by
// the language server to turn a compile into LSP publishDiagnostics rather than writing JSON Lines.
typedef struct {
    const char *file;
    int         line;
    int         col;
    const char *msg;
} DiagInfo;
int diag_count(void);                  // number collected since the last reset
int diag_at(int i, DiagInfo *out);     // fill *out for index i; 1 on success, 0 if out of range

#endif // EMBER_DIAG_H
