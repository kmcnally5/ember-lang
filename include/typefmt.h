#ifndef EMBER_TYPEFMT_H
#define EMBER_TYPEFMT_H

#include "ast.h"

// The one surface-syntax formatter for AST types and function signatures, shared by every
// human-facing consumer so they cannot drift (OFI-034). A type's text ("int", "[string]",
// "Box<int>", "fn(int) -> bool") and a signature's text ("fn name(a: int, mut b: T) -> int") are
// produced here once; callers differ only in WHERE the text goes, which they supply as a sink.
//
// Two related-but-separate renderers are deliberately NOT folded in: src/ast_print.c's
// `print_type` is a debug AST dump with its own conventions (golden-locked, no qualifier,
// "<none>" for unit), and src/check.c's `render_type` formats a resolved `SemType` id rather than
// an AST `Type *` — a different input domain that cannot share this traversal.

// A TypeSink receives the formatter's output: `put` appends a NUL-terminated string to `ctx`
// (e.g. a JsonBuf or a FILE*). This is the only thing a consumer must adapt.
typedef struct {
    void (*put)(void *ctx, const char *s);
    void  *ctx;
} TypeSink;

// Append a type's surface form to `sink`. A NULL type is the unit type, written "()".
void typefmt_type(const TypeSink *sink, const Type *t);

// Append a function's signature ("fn name(params) -> ret") to `sink`, including `self` and the
// `mut`/`move` parameter qualifiers; a NULL return type is omitted (unit).
void typefmt_fn(const TypeSink *sink, const FnDecl *fn);

#endif // EMBER_TYPEFMT_H
