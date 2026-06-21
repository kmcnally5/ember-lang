#include "token.h"

// Name table, indexed by TokenType. Designated initialisers keep each entry
// visually paired with its enum constant, and any token added to the enum
// without a name here shows up immediately as a NULL at runtime.
static const char *const TOKEN_NAMES[TOK_COUNT] = {
    [TOK_EOF]       = "EOF",
    [TOK_ERROR]     = "ERROR",
    [TOK_NEWLINE]   = "NEWLINE",

    [TOK_INT]       = "INT",
    [TOK_FLOAT]     = "FLOAT",
    [TOK_STRING]    = "STRING",
    [TOK_IDENT]     = "IDENT",

    [TOK_LET]       = "LET",
    [TOK_VAR]       = "VAR",
    [TOK_FN]        = "FN",
    [TOK_RETURN]    = "RETURN",
    [TOK_STRUCT]    = "STRUCT",
    [TOK_ENUM]      = "ENUM",
    [TOK_INTERFACE] = "INTERFACE",
    [TOK_IMPLEMENTS] = "IMPLEMENTS",
    [TOK_MATCH]     = "MATCH",
    [TOK_CASE]      = "CASE",
    [TOK_IF]        = "IF",
    [TOK_ELSE]      = "ELSE",
    [TOK_FOR]       = "FOR",
    [TOK_IN]        = "IN",
    [TOK_LOOP]      = "LOOP",
    [TOK_BREAK]     = "BREAK",
    [TOK_CONTINUE]  = "CONTINUE",
    [TOK_NURSERY]   = "NURSERY",
    [TOK_SPAWN]     = "SPAWN",
    [TOK_MOVE]      = "MOVE",
    [TOK_MUT]       = "MUT",
    [TOK_SELF]      = "SELF",
    [TOK_TRUE]      = "TRUE",
    [TOK_FALSE]     = "FALSE",
    [TOK_IMPORT]    = "IMPORT",
    [TOK_AS]        = "AS",

    [TOK_LPAREN]    = "LPAREN",
    [TOK_RPAREN]    = "RPAREN",
    [TOK_LBRACE]    = "LBRACE",
    [TOK_RBRACE]    = "RBRACE",
    [TOK_LBRACKET]  = "LBRACKET",
    [TOK_RBRACKET]  = "RBRACKET",
    [TOK_COMMA]     = "COMMA",
    [TOK_DOT]       = "DOT",
    [TOK_DOTDOT]    = "DOTDOT",
    [TOK_COLON]     = "COLON",
    [TOK_ARROW]     = "ARROW",
    [TOK_QUESTION]  = "QUESTION",

    [TOK_ASSIGN]    = "ASSIGN",
    [TOK_EQ]        = "EQ",
    [TOK_NEQ]       = "NEQ",
    [TOK_LT]        = "LT",
    [TOK_LE]        = "LE",
    [TOK_GT]        = "GT",
    [TOK_GE]        = "GE",
    [TOK_PLUS]      = "PLUS",
    [TOK_MINUS]     = "MINUS",
    [TOK_STAR]      = "STAR",
    [TOK_SLASH]     = "SLASH",
    [TOK_PERCENT]   = "PERCENT",
    [TOK_BANG]      = "BANG",
    [TOK_AND]       = "AND",
    [TOK_OR]        = "OR",
    [TOK_PIPE]      = "PIPE",
    [TOK_AMP]       = "AMP",
    [TOK_CARET]     = "CARET",
    [TOK_TILDE]     = "TILDE",
    [TOK_SHL]       = "SHL",
    [TOK_SHR]       = "SHR",
};

const char *token_type_name(TokenType type) {
    if (type < 0 || type >= TOK_COUNT || TOKEN_NAMES[type] == NULL) {
        return "INVALID";
    }
    return TOKEN_NAMES[type];
}
