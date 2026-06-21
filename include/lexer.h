#ifndef EMBER_LEXER_H
#define EMBER_LEXER_H

#include "token.h"
#include <stddef.h>

// A growable, owning array of Tokens produced by a single scan. The Tokens
// themselves point into the source buffer passed to lexer_scan (see token.h),
// so that buffer must outlive the TokenList. `had_error` is set if any
// TOK_ERROR was emitted during the scan.
typedef struct {
    Token  *tokens;
    size_t  count;
    size_t  capacity;
    int     had_error;
} TokenList;

// Scans the entire NUL-terminated `source` into a TokenList. `source_name` is the
// file name reported in lexical diagnostics (it flows through diag_error, so lexer
// errors render as `file:line:col: error: …` and appear under `--diagnostics=json`).
// The stream always ends with exactly one TOK_EOF. On a lexical error the scanner
// emits a TOK_ERROR token spanning the offending text, sets had_error, and keeps
// going so a single run can report every problem. The caller owns the result and
// must release it with token_list_free.
TokenList lexer_scan(const char *source, const char *source_name);

// Frees the token array and resets the list to empty. Safe to call on a
// zero-initialised list.
void token_list_free(TokenList *list);

#endif // EMBER_LEXER_H
