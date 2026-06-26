#ifndef EMBER_TOKEN_H
#define EMBER_TOKEN_H

#include <stddef.h>

// TokenType enumerates every lexical category Ember's scanner can produce.
// The order is not significant except that TOK_COUNT must stay last so it
// records the total and can size the name table in token.c.
typedef enum {
    // Stream control
    TOK_EOF,          // end of input
    TOK_ERROR,        // an unrecognised or malformed lexeme (lexeme = offending text)
    TOK_NEWLINE,      // implicit statement terminator at a significant line break

    // Literals and names
    TOK_INT,          // 2026
    TOK_FLOAT,        // 3.14159
    TOK_STRING,       // "..."  (raw, including quotes; escapes/interpolation decoded later)
    TOK_IDENT,        // identifiers and as-yet-unreserved type names (int, float, ...)

    // Keywords — chosen per the MANIFESTO §5b "least surprise, for the model" principle
    TOK_LET, TOK_VAR, TOK_FN, TOK_RETURN,
    TOK_STRUCT, TOK_ENUM, TOK_INTERFACE, TOK_IMPLEMENTS,
    TOK_MATCH, TOK_CASE,
    TOK_IF, TOK_ELSE, TOK_FOR, TOK_IN, TOK_LOOP, TOK_BREAK, TOK_CONTINUE,
    TOK_NURSERY, TOK_SPAWN,
    TOK_MOVE, TOK_MUT, TOK_SELF,
    TOK_TRUE, TOK_FALSE,
    TOK_IMPORT, TOK_AS,
    TOK_EXTERN,                    // extern "c" { ... } — foreign (C) functions (§5h)
    TOK_TYPE,                      // type X = Base — a distinct nominal type (OFI-149)
    TOK_WHERE,                     // type X = Base where P — a refinement predicate (OFI-150)
    TOK_REQUIRES, TOK_ENSURES,     // function contracts (pre/post-conditions)

    // Delimiters
    TOK_LPAREN, TOK_RPAREN,        // ( )
    TOK_LBRACE, TOK_RBRACE,        // { }
    TOK_LBRACKET, TOK_RBRACKET,    // [ ]
    TOK_COMMA, TOK_DOT, TOK_DOTDOT, TOK_COLON, // , . .. :
    TOK_ARROW,                     // ->
    TOK_QUESTION,                  // ?

    // Operators
    TOK_ASSIGN,                          // =
    TOK_EQ, TOK_NEQ,                     // == !=
    TOK_LT, TOK_LE, TOK_GT, TOK_GE,      // < <= > >=
    TOK_PLUS, TOK_MINUS, TOK_STAR,       // + - *
    TOK_SLASH, TOK_PERCENT,              // / %
    TOK_BANG, TOK_AND, TOK_OR,           // ! && ||
    TOK_PIPE,                            // |   (lambda delimiter AND bitwise-or — position disambiguates)
    TOK_AMP, TOK_CARET, TOK_TILDE,       // & ^ ~  (bitwise and / xor / not)
    TOK_SHL, TOK_SHR,                    // << >>  (left / right shift)

    TOK_COUNT
} TokenType;

// A Token is a zero-copy view into the source buffer: `start` points into the
// original text and `length` is the lexeme's byte count. The source buffer must
// therefore outlive every Token derived from it. `line`/`col` are 1-based and
// mark the lexeme's first character.
typedef struct {
    TokenType   type;
    const char *start;
    size_t      length;
    int         line;
    int         col;
    // A `///` doc-comment block immediately preceding this token, as a raw view
    // into the source (the `///` markers and inter-line newlines are still
    // present; a consumer strips them — see the parser's doc cleaner). NULL/0
    // when no doc comment precedes the token. Only the first token of a
    // declaration carries it; everything else leaves it NULL.
    const char *doc;
    size_t      doc_length;
} Token;

// Returns a stable, human-readable name for a token type (e.g. "LET", "ARROW").
// Out-of-range values return "INVALID".
const char *token_type_name(TokenType type);

#endif // EMBER_TOKEN_H
