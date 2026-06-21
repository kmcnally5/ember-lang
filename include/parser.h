#ifndef EMBER_PARSER_H
#define EMBER_PARSER_H

#include "ast.h"
#include "arena.h"
#include "token.h"
#include <stddef.h>

// Parses a token stream (as produced by lexer_scan, including its TOK_NEWLINE
// terminators and trailing TOK_EOF) into a Program.
//
// Every AST node and child array is allocated from `arena`, which the caller
// owns and must release with arena_free once the tree is no longer needed.
// String contents referenced by the tree (identifiers, literal text) are copied
// into the arena, so the tree does not depend on the original token buffer
// outliving it.
//
// `source_name` labels diagnostics. On a syntax error the parser prints a
// message to stderr, sets *had_error to 1, recovers to the next statement or
// declaration boundary, and continues, so one run reports multiple errors. The
// returned Program contains everything that parsed successfully.
Program parser_parse(const Token *tokens, size_t count, Arena *arena,
                     const char *source_name, int *had_error);

#endif // EMBER_PARSER_H
