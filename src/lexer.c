#include "lexer.h"

#include "diag.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Scanner holds the moving state of a single scan. `cur` points at the next
// byte to consume; `line`/`col` are the 1-based position of that byte. We track
// position as we advance so each token can record where it began.
typedef struct {
    const char *cur;
    const char *file;       // source name, for diagnostics (diag_error)
    int         line;
    int         col;
    int         had_error;
    // Pending `///` doc-comment block, gathered by skip_trivia and handed to the
    // next real token by lexer_scan. `doc_start`/`doc_end` bound the raw block in
    // the source; `doc_last_line` lets consecutive `///` lines coalesce into one
    // block while a blank or non-doc line starts a fresh one.
    const char *doc_start;
    const char *doc_end;
    int         doc_last_line;
} Scanner;

// Records a lexical error through the diagnostics layer and returns a TOK_ERROR
// token; defined below scan_string, which is its first caller.
static Token lex_error(Scanner *s, const char *start, int line, int col,
                       const char *msg, const char *near, const char *help);

// Classification helpers. We hand-roll these rather than use <ctype.h> so the
// result never depends on locale and char-signedness is a non-issue.
static int is_digit(char c) {
    return c >= '0' && c <= '9';
}




static int is_alpha(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}





static int is_alnum(char c) {
    return is_digit(c) || is_alpha(c);
}





// peek returns the current byte without consuming it.
static char peek(Scanner *s) {
    return *s->cur;
}





// peek_next returns the byte after the current one, never reading past the NUL.
static char peek_next(Scanner *s) {
    return (*s->cur == '\0') ? '\0' : s->cur[1];
}





// advance consumes and returns the current byte, keeping line/col in step.
static char advance(Scanner *s) {
    char c = *s->cur++;
    if (c == '\n') {
        s->line++;
        s->col = 1;
    } else {
        s->col++;
    }
    return c;
}





// match consumes the current byte only if it equals `expected`.
static int match(Scanner *s, char expected) {
    if (*s->cur != expected) {
        return 0;
    }
    advance(s);
    return 1;
}





// mk builds a token spanning [start, cur). Because cur has already advanced past
// the lexeme, the length is simply the pointer difference — uniform for one-byte
// punctuation, multi-byte operators, identifiers, numbers, and strings alike.
static Token mk(Scanner *s, TokenType type, const char *start, int line, int col) {
    Token t;
    t.type       = type;
    t.start      = start;
    t.length     = (size_t)(s->cur - start);
    t.line       = line;
    t.col        = col;
    t.doc        = NULL;     // attached (if any) by lexer_scan, never by mk
    t.doc_length = 0;
    return t;
}





// push_token appends to the growable list, doubling capacity as needed. A
// compiler that cannot allocate cannot continue, so OOM is fatal.
static void push_token(TokenList *list, Token t) {
    if (list->count == list->capacity) {
        size_t new_cap = list->capacity ? list->capacity * 2 : 16;
        Token *grown = realloc(list->tokens, new_cap * sizeof(Token));
        if (grown == NULL) {
            fprintf(stderr, "emberc: out of memory while scanning\n");
            exit(70);
        }
        list->tokens   = grown;
        list->capacity = new_cap;
    }
    list->tokens[list->count++] = t;
}





// skip_trivia consumes whitespace and `//` line comments, leaving cur at the
// first byte of the next real token (or the NUL). It returns 1 if any newline
// was crossed, so the scanner can decide whether to insert a statement
// terminator (see should_terminate).
static int skip_trivia(Scanner *s) {
    int crossed_newline = 0;
    for (;;) {
        char c = peek(s);
        if (c == '\n') {
            crossed_newline = 1;
            advance(s);
        } else if (c == ' ' || c == '\t' || c == '\r') {
            advance(s);
        } else if (c == '/' && peek_next(s) == '/') {
            // A doc comment is exactly `///` (not `//` and not `////`+), matching the
            // Rust/Go/clang convention. Its text feeds hover and `--emit=docs`; an
            // ordinary `//` is discarded. Adjacent `///` lines coalesce into one block.
            const char *line_start = s->cur;
            int is_doc = (s->cur[2] == '/' && s->cur[3] != '/');
            int line   = s->line;
            while (peek(s) != '\n' && peek(s) != '\0') {
                advance(s);
            }
            if (is_doc) {
                if (s->doc_start != NULL && line == s->doc_last_line + 1) {
                    s->doc_end = s->cur;                  // extend the running block
                } else {
                    s->doc_start = line_start;            // begin a fresh block
                    s->doc_end   = s->cur;
                }
                s->doc_last_line = line;
            }
        } else {
            return crossed_newline;
        }
    }
}





// should_terminate decides whether a newline following a token of type `prev`
// ends a statement. Per MANIFESTO §5b this is true exactly when `prev` can be
// the last token of a statement — a value, a closing bracket, a postfix `?`, or
// a standalone control keyword. After anything else (operators, commas, opening
// brackets) the newline is insignificant and the statement continues.
static int should_terminate(TokenType prev) {
    switch (prev) {
        case TOK_INT:
        case TOK_FLOAT:
        case TOK_STRING:
        case TOK_IDENT:
        case TOK_TRUE:
        case TOK_FALSE:
        case TOK_SELF:
        case TOK_RETURN:
        case TOK_BREAK:
        case TOK_CONTINUE:
        case TOK_RPAREN:
        case TOK_RBRACKET:
        case TOK_RBRACE:
        case TOK_QUESTION:
            return 1;
        default:
            return 0;
    }
}





// keyword_type returns the reserved-word token for a lexeme, or TOK_IDENT if the
// lexeme is an ordinary identifier. Linear scan over a small table is plenty
// fast at this scale and keeps the keyword set in one obvious place.
static TokenType keyword_type(const char *text, size_t length) {
    static const struct {
        const char *word;
        TokenType   type;
    } KEYWORDS[] = {
        // The reserved-word set is generated from the single source of truth so the lexer
        // cannot drift from the LSP or the editor grammar (see include/vocab.def, OFI-033).
        #define EMBER_KEYWORD(tok, word, cat, gloss) { word, tok },
        #include "vocab.def"
    };
    size_t count = sizeof(KEYWORDS) / sizeof(KEYWORDS[0]);
    for (size_t i = 0; i < count; i++) {
        if (strlen(KEYWORDS[i].word) == length &&
            memcmp(KEYWORDS[i].word, text, length) == 0) {
            return KEYWORDS[i].type;
        }
    }
    return TOK_IDENT;
}





// scan_identifier consumes an identifier run and resolves it to a keyword or
// TOK_IDENT. The opening character has already been consumed by the caller.
static Token scan_identifier(Scanner *s, const char *start, int line, int col) {
    while (is_alnum(peek(s))) {
        advance(s);
    }
    size_t length = (size_t)(s->cur - start);
    return mk(s, keyword_type(start, length), start, line, col);
}





// scan_number consumes an integer, promoting to a float only when a '.' is
// followed by another digit. That look-ahead keeps `3.0` a float while leaving
// `self.x` as IDENT DOT IDENT rather than swallowing the dot.
static Token scan_number(Scanner *s, const char *start, int line, int col) {
    while (is_digit(peek(s))) {
        advance(s);
    }
    if (peek(s) == '.' && is_digit(peek_next(s))) {
        advance(s); // consume '.'
        while (is_digit(peek(s))) {
            advance(s);
        }
        return mk(s, TOK_FLOAT, start, line, col);
    }
    // A width suffix, `i`/`u` followed by digits (e.g. `255u8`), is folded into the
    // integer lexeme; the parser validates and maps it. The digit look-ahead keeps
    // an adjacent identifier (`5x`) from being mistaken for a suffix.
    if ((peek(s) == 'i' || peek(s) == 'u') && is_digit(peek_next(s))) {
        advance(s);                 // 'i' or 'u'
        while (is_digit(peek(s))) {
            advance(s);
        }
    }
    return mk(s, TOK_INT, start, line, col);
}





// scan_string consumes a "..." literal, including the closing quote. Escapes are
// skipped over (decoding is deferred to a later phase) and embedded newlines are
// permitted. An unterminated literal yields a TOK_ERROR spanning what was read.
// Interpolation braces are left inside the lexeme for the parser to split out —
// and a `"` *inside* an interpolation hole (e.g. `"{a.split(",")}"`) opens a
// nested string literal, not the end of this one, so brace depth is tracked and a
// nested string is consumed whole before the outer `"` can close the literal.
static Token scan_string(Scanner *s, const char *start, int line, int col) {
    int depth = 0;          // interpolation-hole nesting (`{ … }`)
    int brace_line = line;  // position of the first still-open interpolation brace, for the
    int brace_col = col;    // error when one is left unmatched (almost always a literal `{` that
                            // should have been written `\{`).
    for (;;) {
        char c = peek(s);
        if (c == '\0') {
            break;
        }
        if (c == '\\' && peek_next(s) != '\0') {
            advance(s);                 // backslash
            advance(s);                 // the escaped char (\" \{ \} \n …)
            continue;
        }
        if (c == '"') {
            if (depth == 0) {
                break;                  // the closing quote of this literal
            }
            advance(s);                 // a nested string in a hole — consume it
            while (peek(s) != '"' && peek(s) != '\0') {
                if (peek(s) == '\\' && peek_next(s) != '\0') {
                    advance(s);
                }
                advance(s);
            }
            if (peek(s) == '"') {
                advance(s);             // the nested string's closing quote
            }
            continue;
        }
        if (c == '{') {
            if (depth == 0) {           // remember where the outermost hole opened
                brace_line = s->line;
                brace_col = s->col;
            }
            depth++;
        } else if (c == '}' && depth > 0) {
            depth--;
        }
        advance(s);
    }
    if (peek(s) == '\0') {
        // An unmatched `{` ran the scan to EOF: the `"` that should have closed the string was
        // instead read as the start of a nested string inside the still-open interpolation. Point at
        // the brace and say so — a bare `{`/`}` in string text must be escaped as `\{`/`\}`.
        if (depth > 0) {
            return lex_error(s, start, brace_line, brace_col,
                             "unterminated interpolation '{ }' in this string", NULL,
                             "close it with '}', or write '\\{' for a literal brace");
        }
        return lex_error(s, start, line, col,
                         "unterminated string literal", NULL,
                         "add a closing '\"'");
    }
    advance(s); // closing quote
    return mk(s, TOK_STRING, start, line, col);
}





// lex_error records a lexical error through the diagnostics layer (so it renders as
// `file:line:col: error: …` in human mode and is collected for `--diagnostics=json`,
// closing OFI-022) and returns the TOK_ERROR token spanning the offending lexeme.
static Token lex_error(Scanner *s, const char *start, int line, int col,
                       const char *msg, const char *near, const char *help) {
    s->had_error = 1;
    diag_error(s->file, line, col, msg, near, help);
    return mk(s, TOK_ERROR, start, line, col);
}




// scan_token reads exactly one token starting at the current position, which is
// guaranteed by the caller to be a non-trivia, non-EOF byte.
static Token scan_token(Scanner *s) {
    const char *start = s->cur;
    int line = s->line;
    int col  = s->col;
    char c   = advance(s);

    switch (c) {
        case '(': return mk(s, TOK_LPAREN, start, line, col);
        case ')': return mk(s, TOK_RPAREN, start, line, col);
        case '{': return mk(s, TOK_LBRACE, start, line, col);
        case '}': return mk(s, TOK_RBRACE, start, line, col);
        case '[': return mk(s, TOK_LBRACKET, start, line, col);
        case ']': return mk(s, TOK_RBRACKET, start, line, col);
        case ',': return mk(s, TOK_COMMA, start, line, col);
        case '.': return mk(s, match(s, '.') ? TOK_DOTDOT : TOK_DOT, start, line, col);
        case ':': return mk(s, TOK_COLON, start, line, col);
        case '?': return mk(s, TOK_QUESTION, start, line, col);
        case '+': return mk(s, TOK_PLUS, start, line, col);
        case '*': return mk(s, TOK_STAR, start, line, col);
        case '/': return mk(s, TOK_SLASH, start, line, col);
        case '%': return mk(s, TOK_PERCENT, start, line, col);

        case '-': return mk(s, match(s, '>') ? TOK_ARROW : TOK_MINUS, start, line, col);
        case '=': return mk(s, match(s, '=') ? TOK_EQ : TOK_ASSIGN, start, line, col);
        case '!': return mk(s, match(s, '=') ? TOK_NEQ : TOK_BANG, start, line, col);
        // '<' / '>' carry three forms each: '<<'/'>>' shift, '<='/'>=' compare, bare
        // '<'/'>'. The shift form is checked first (it would otherwise read as two
        // comparison tokens). A '>>' that actually closes nested generics (Box<Box<int>>)
        // is split back into two '>' by the type parser — the standard C++/Rust/Java trick.
        case '<':
            if (match(s, '<')) return mk(s, TOK_SHL, start, line, col);
            return mk(s, match(s, '=') ? TOK_LE : TOK_LT, start, line, col);
        case '>':
            if (match(s, '>')) return mk(s, TOK_SHR, start, line, col);
            return mk(s, match(s, '=') ? TOK_GE : TOK_GT, start, line, col);

        // '&&' is logical and; a lone '&' is bitwise and. (Ownership is keyword-based,
        // not sigil-based — '&' is NOT a reference operator; MANIFESTO §5b.)
        case '&':
            if (match(s, '&')) return mk(s, TOK_AND, start, line, col);
            return mk(s, TOK_AMP, start, line, col);
        // '||' is logical or; a lone '|' is BOTH the lambda delimiter (`|x| x + 1`, in
        // operand position) and bitwise-or (`a | b`, in operator position) — the parser
        // tells them apart by grammar position, so one token serves both.
        case '|':
            if (match(s, '|')) return mk(s, TOK_OR, start, line, col);
            return mk(s, TOK_PIPE, start, line, col);
        case '^': return mk(s, TOK_CARET, start, line, col);
        case '~': return mk(s, TOK_TILDE, start, line, col);

        case '"': return scan_string(s, start, line, col);

        default:
            if (is_digit(c)) {
                return scan_number(s, start, line, col);
            }
            if (is_alpha(c)) {
                return scan_identifier(s, start, line, col);
            }
            char near[2] = { c, '\0' };
            return lex_error(s, start, line, col,
                             "unexpected character", near, NULL);
    }
}





TokenList lexer_scan(const char *source, const char *source_name) {
    TokenList list = {0};
    Scanner s = { .cur = source, .file = source_name,
                  .line = 1, .col = 1, .had_error = 0 };

    // The token preceding the current one, used to decide statement
    // termination. Seeded with TOK_NEWLINE so leading blank lines never emit a
    // terminator (nothing precedes them).
    TokenType prev = TOK_NEWLINE;

    // Depth of unclosed `(`/`[`. A newline inside a grouped expression, call
    // argument list, or array literal continues it — so an expression may span
    // lines by wrapping it in parentheses (braces are *not* counted: they delimit
    // blocks, where newlines do separate statements).
    int bracket_depth = 0;

    for (;;) {
        int crossed_newline = skip_trivia(&s);
        if (crossed_newline && bracket_depth == 0 && should_terminate(prev)) {
            Token term = mk(&s, TOK_NEWLINE, s.cur, s.line, s.col);
            push_token(&list, term);
            prev = TOK_NEWLINE;
        }

        if (peek(&s) == '\0') {
            push_token(&list, mk(&s, TOK_EOF, s.cur, s.line, s.col));
            break;
        }

        Token t = scan_token(&s);
        if (s.doc_start != NULL) {
            // Hand the gathered `///` block to this token (the first token after the
            // comment — typically a declaration keyword) and clear it so the next
            // declaration starts fresh.
            t.doc        = s.doc_start;
            t.doc_length = (size_t)(s.doc_end - s.doc_start);
            s.doc_start  = NULL;
            s.doc_end    = NULL;
        }
        push_token(&list, t);
        prev = t.type;
        if (t.type == TOK_LPAREN || t.type == TOK_LBRACKET) {
            bracket_depth++;
        } else if ((t.type == TOK_RPAREN || t.type == TOK_RBRACKET) &&
                   bracket_depth > 0) {
            bracket_depth--;
        }
    }

    list.had_error = s.had_error;
    return list;
}





void token_list_free(TokenList *list) {
    free(list->tokens);
    list->tokens    = NULL;
    list->count     = 0;
    list->capacity  = 0;
    list->had_error = 0;
}
