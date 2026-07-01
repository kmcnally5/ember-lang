#include "parser.h"
#include "lexer.h"
#include "diag.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_STR_PARTS 128

// Parser holds the scan position over a token array plus the arena that owns the
// resulting tree. `no_struct` suppresses brace struct-literals while parsing the
// condition/scrutinee of if/for/match, so the following `{` reads as a block
// rather than a struct literal (the same disambiguation Rust uses). `panic`
// suppresses cascading messages until the next synchronisation point.
typedef struct {
    const Token *toks;
    size_t       count;
    size_t       pos;
    Arena       *arena;
    const char  *src_name;
    int          had_error;
    int          panic;
    int          no_struct;
    int          depth;          // recursion depth of the expr/type descent (overflow guard)
} Parser;

// Cap on recursive-descent nesting for expressions and types. Hand-written recursive
// descent has no stack-overflow protection, so deeply nested input (`((((…))))`, a long
// `---…` chain, `[[[…]]]`) would otherwise crash emberc with a SIGSEGV instead of a clean
// diagnostic. 1000 is far beyond any human-written nesting yet leaves ample C stack.
#define MAX_PARSE_DEPTH 1000

// ---- A small generic vector, used to gather child nodes whose count is not
// known up front. It is malloc-backed during the parse, then copied into the
// arena and freed; the arena copy is what the tree keeps.
typedef struct {
    unsigned char *data;
    size_t         len;
    size_t         cap;
    size_t         elem;
} Vec;

static void vec_init(Vec *v, size_t elem) {
    v->data = NULL;
    v->len  = 0;
    v->cap  = 0;
    v->elem = elem;
}





static void vec_push(Vec *v, const void *elem) {
    if (v->len == v->cap) {
        size_t new_cap = v->cap ? v->cap * 2 : 8;
        unsigned char *grown = realloc(v->data, new_cap * v->elem);
        if (grown == NULL) {
            fprintf(stderr, "emberc: out of memory while parsing\n");
            exit(70);
        }
        v->data = grown;
        v->cap  = new_cap;
    }
    memcpy(v->data + v->len * v->elem, elem, v->elem);
    v->len++;
}





// vec_to_arena copies the gathered elements into the arena, reports the count,
// frees the scratch buffer, and returns the arena array (NULL when empty).
static void *vec_to_arena(Arena *arena, Vec *v, size_t *out_count) {
    *out_count = v->len;
    void *out = NULL;
    if (v->len > 0) {
        out = arena_alloc(arena, v->len * v->elem);
        memcpy(out, v->data, v->len * v->elem);
    }
    free(v->data);
    v->data = NULL;
    v->len  = 0;
    v->cap  = 0;
    return out;
}





// ---- Token cursor helpers. ----

static const Token *cur(Parser *p) {
    return &p->toks[p->pos];
}





static TokenType pk(Parser *p) {
    return p->toks[p->pos].type;
}


// pk2 peeks the token AFTER the current one (the token list is EOF-terminated, so this is in-bounds
// whenever the current token is not EOF). Used to spot a `name:` named argument (IDENT then COLON).
static TokenType pk2(Parser *p) {
    return p->toks[p->pos].type == TOK_EOF ? TOK_EOF : p->toks[p->pos + 1].type;
}





static const Token *adv(Parser *p) {
    const Token *t = &p->toks[p->pos];
    if (p->toks[p->pos].type != TOK_EOF) {
        p->pos++;
    }
    return t;
}





static int check(Parser *p, TokenType t) {
    return pk(p) == t;
}





static int match(Parser *p, TokenType t) {
    if (check(p, t)) {
        adv(p);
        return 1;
    }
    return 0;
}





static int at_end(Parser *p) {
    return pk(p) == TOK_EOF;
}





static void skip_newlines(Parser *p) {
    while (check(p, TOK_NEWLINE)) {
        adv(p);
    }
}





static const char *tok_text(Parser *p, const Token *t) {
    return arena_strndup(p->arena, t->start, t->length);
}




// tok_doc turns a token's raw `///` doc-comment block (a view into the source,
// with the markers and inter-line newlines intact — see lexer.c) into a tidy,
// arena-allocated Markdown string: each line's leading whitespace, its `///`
// marker, and one following space are stripped, and the lines are rejoined with
// '\n'. Returns NULL when the token carries no doc comment. This is the single
// place doc text is cleaned, so hover and `--emit=docs` render it identically.
static const char *tok_doc(Parser *p, const Token *t) {
    if (t->doc == NULL || t->doc_length == 0) {
        return NULL;
    }
    char       *out  = arena_alloc(p->arena, t->doc_length + 1);  // never exceeds the span
    size_t      o    = 0;
    const char *cur  = t->doc;
    const char *end  = t->doc + t->doc_length;
    int         first = 1;
    while (cur < end) {
        const char *nl = cur;
        while (nl < end && *nl != '\n') {
            nl++;
        }
        const char *ln = cur;                       // strip indent, `///`, one space
        while (ln < nl && (*ln == ' ' || *ln == '\t')) {
            ln++;
        }
        if (nl - ln >= 3 && ln[0] == '/' && ln[1] == '/' && ln[2] == '/') {
            ln += 3;
        }
        if (ln < nl && *ln == ' ') {
            ln++;
        }
        const char *le = nl;                        // drop a trailing '\r'
        if (le > ln && le[-1] == '\r') {
            le--;
        }
        if (!first) {
            out[o++] = '\n';
        }
        memcpy(out + o, ln, (size_t)(le - ln));
        o += (size_t)(le - ln);
        first = 0;
        cur = (nl < end) ? nl + 1 : end;
    }
    out[o] = '\0';
    return out;
}





// ---- Error reporting and recovery. ----

static void error_at(Parser *p, const Token *t, const char *msg) {
    if (!p->panic) {
        // Build the NUL-terminated "near" token text (full length, no truncation,
        // so the human rendering stays byte-identical to the old %.*s form).
        char  stackbuf[128];
        char *near = stackbuf;
        if (t->length + 1 > sizeof stackbuf) {
            near = malloc(t->length + 1);
        }
        if (near != NULL) {
            memcpy(near, t->start, t->length);
            near[t->length] = '\0';
            diag_error(p->src_name, t->line, t->col, msg, near, NULL);
            if (near != stackbuf) {
                free(near);
            }
        }
    }
    p->had_error = 1;
    p->panic     = 1;
}





// expect consumes a token of the given type, or reports `msg` and returns the
// current token without advancing.
static const Token *expect(Parser *p, TokenType t, const char *msg) {
    if (check(p, t)) {
        return adv(p);
    }
    error_at(p, cur(p), msg);
    return cur(p);
}





// synchronize discards tokens until a likely statement/declaration boundary so
// that one syntax error does not cascade into a flood of spurious ones.
static void synchronize(Parser *p) {
    p->panic = 0;
    while (!at_end(p)) {
        if (check(p, TOK_NEWLINE)) {
            adv(p);
            return;
        }
        switch (pk(p)) {
            case TOK_FN:
            case TOK_STRUCT:
            case TOK_ENUM:
            case TOK_INTERFACE:
            case TOK_IMPORT:
            case TOK_LET:
            case TOK_VAR:
            case TOK_RETURN:
            case TOK_IF:
            case TOK_FOR:
            case TOK_LOOP:
            case TOK_MATCH:
            case TOK_NURSERY:
            case TOK_SPAWN:
            case TOK_RBRACE:
                return;
            default:
                adv(p);
        }
    }
}





// ---- Node allocators (line/col seeded from the current token). ----

// suffix_code maps an integer-literal width suffix to a small code the checker
// turns into a type: 1 i8, 2 i16, 3 i32, 4 i64, 5 u8, 6 u16, 7 u32, 8 u64; 0 = unknown.
// (The parser can't name the checker's SemType constants, so it passes a code.)
static int suffix_code(const char *s, size_t len) {
    if (len == 2 && s[0] == 'i' && s[1] == '8') return 1;
    if (len == 3 && strncmp(s, "i16", 3) == 0)  return 2;
    if (len == 3 && strncmp(s, "i32", 3) == 0)  return 3;
    if (len == 3 && strncmp(s, "i64", 3) == 0)  return 4;
    if (len == 2 && s[0] == 'u' && s[1] == '8') return 5;
    if (len == 3 && strncmp(s, "u16", 3) == 0)  return 6;
    if (len == 3 && strncmp(s, "u32", 3) == 0)  return 7;
    if (len == 3 && strncmp(s, "u64", 3) == 0)  return 8;
    return 0;
}


static Expr *new_expr(Parser *p, ExprKind kind) {
    Expr *e = arena_alloc(p->arena, sizeof(Expr));
    // Zero the whole node first: the arena does not clear memory, so any per-kind
    // `as.*` field a creation site forgets to set would otherwise be garbage — a latent
    // bug that only surfaces when the allocation pattern changes (e.g. `closure_call`,
    // which a non-closure call never sets; see OFI-026). Fields needing a non-zero
    // default (resolved_fn = -1, since 0 is a valid fn index) are set explicitly at
    // their creation site and override this.
    memset(e, 0, sizeof(*e));
    e->kind = kind;
    e->line = cur(p)->line;
    e->col  = cur(p)->col;
    e->variant_enum_id = -1;   // 0 is a valid enum id, so default to "not a variant" explicitly
    e->variant_tag     = -1;
    return e;
}





static Stmt *new_stmt(Parser *p, StmtKind kind) {
    // Arena memory is not zeroed, so clear the whole node — same hardening as new_expr
    // and new_type (OFI-026). Per-kind `as.*` flags that codegen reads but the checker
    // only sets on some paths (STMT_EXPR.release_temp, STMT_MATCH.subject_drop) would
    // otherwise be recycled garbage, e.g. a spurious OP_RELEASE → double-free.
    Stmt *s = arena_alloc(p->arena, sizeof(Stmt));
    memset(s, 0, sizeof(*s));
    s->kind = kind;
    s->line = cur(p)->line;
    s->col  = cur(p)->col;
    return s;
}





static Type *new_type(Parser *p, TypeKind kind) {
    // Arena memory is not zeroed, so clear the whole node: every per-kind `as.*`
    // field a caller leaves unset (e.g. the optional `qualifier` on a bare
    // struct-literal type) must read as 0/NULL, not recycled garbage. Same class
    // of bug as the new_expr memset (OFI-026).
    Type *t = arena_alloc(p->arena, sizeof(Type));
    memset(t, 0, sizeof(Type));
    t->kind = kind;
    t->line = cur(p)->line;
    t->col  = cur(p)->col;
    return t;
}





// ---- Forward declarations for the mutually recursive descent. ----

static Expr  *parse_expression(Parser *p);
static Type  *parse_type(Parser *p);
static Stmt  *parse_statement(Parser *p);
static Block  parse_block(Parser *p);
static Decl  *parse_decl(Parser *p);
static FnDecl parse_fn(Parser *p, int with_body);
static void  expect_type_close(Parser *p);





// ---- Types. ----

static Type *parse_type(Parser *p) {
    if (++p->depth > MAX_PARSE_DEPTH) {
        error_at(p, cur(p), "type nests too deeply");
        p->depth--;
        Type *stub = new_type(p, TYPE_NAME);   // benign placeholder; panic now unwinds
        stub->as.name.name = "_";
        return stub;
    }
    Type *t;
    if (check(p, TOK_LBRACKET)) {
        adv(p);
        Type *elem = parse_type(p);
        expect(p, TOK_RBRACKET, "expected ']' to close array type");
        t = new_type(p, TYPE_ARRAY);
        t->as.array.elem = elem;
    } else if (check(p, TOK_FN)) {
        // A function type: `fn(T1, T2) -> R`. A missing `-> R` means it returns
        // unit. This is the type of a function value (a named function or a lambda).
        adv(p);   // 'fn'
        t = new_type(p, TYPE_FN);
        expect(p, TOK_LPAREN, "expected '(' after 'fn' in a function type");
        Vec params;
        vec_init(&params, sizeof(Type *));
        if (!check(p, TOK_RPAREN)) {
            for (;;) {
                Type *param = parse_type(p);
                vec_push(&params, &param);
                if (match(p, TOK_COMMA)) {
                    continue;
                }
                break;
            }
        }
        expect(p, TOK_RPAREN, "expected ')' to close a function type's parameters");
        t->as.fn.params = vec_to_arena(p->arena, &params, &t->as.fn.param_count);
        t->as.fn.ret = match(p, TOK_ARROW) ? parse_type(p) : NULL;
    } else {
        const Token *name_tok = expect(p, TOK_IDENT, "expected a type name");
        const char *name = tok_text(p, name_tok);
        // Remember the NAME token's position: new_type() below records cur(p), which by
        // then sits PAST the type, so the LSP would key hover/go-to-def at the wrong spot.
        const Token *pos_tok = name_tok;
        // A module-qualified type path: `mod.Type` — the first ident is the alias.
        const char *qualifier = NULL;
        if (match(p, TOK_DOT)) {
            qualifier = name;
            const Token *mem_tok = expect(p, TOK_IDENT,
                                          "expected a type name after '.'");
            name = tok_text(p, mem_tok);
            pos_tok = mem_tok;   // position the type at its NAME, not the `.` qualifier
        }
        if (match(p, TOK_LT)) {
            Vec args;
            vec_init(&args, sizeof(Type *));
            for (;;) {
                Type *arg = parse_type(p);
                vec_push(&args, &arg);
                if (match(p, TOK_COMMA)) {
                    continue;
                }
                break;
            }
            expect_type_close(p);
            t = new_type(p, TYPE_GENERIC);
            t->as.generic.qualifier = qualifier;
            t->as.generic.name = name;
            t->as.generic.args = vec_to_arena(p->arena, &args,
                                              &t->as.generic.arg_count);
        } else {
            t = new_type(p, TYPE_NAME);
            t->as.name.qualifier = qualifier;
            t->as.name.name = name;
        }
        t->line = pos_tok->line;   // key the node at its name (for LSP hover/go-to-def)
        t->col  = pos_tok->col;
    }
    p->depth--;
    return t;
}





// ---- Expressions (recursive descent with precedence climbing). ----

// binary_prec returns the binding power of a binary operator, or 0 if `t` is not
// one. Higher binds tighter. All Ember binary operators are left-associative.
static int binary_prec(TokenType t) {
    switch (t) {
        case TOK_OR:                                   return 1;   // ||
        case TOK_AND:                                  return 2;   // &&
        case TOK_PIPE:                                 return 3;   // |  (bitwise or)
        case TOK_CARET:                                return 4;   // ^  (bitwise xor)
        case TOK_AMP:                                  return 5;   // &  (bitwise and)
        case TOK_EQ:  case TOK_NEQ:                    return 6;   // == !=
        case TOK_LT:  case TOK_LE: case TOK_GT: case TOK_GE: return 7;   // < <= > >=
        case TOK_SHL: case TOK_SHR:                    return 8;   // << >>
        case TOK_PLUS: case TOK_MINUS:                 return 9;   // + -
        case TOK_STAR: case TOK_SLASH: case TOK_PERCENT: return 10;  // * / %
        default:                                       return 0;
    }
}





// looks_like_generic_struct_lit decides, from a '<' following a type name in
// expression position, whether this is a generic struct literal `Name<T> { … }`
// rather than a less-than comparison. This is a SOUND decision, not a heuristic
// (OFI-002): the rule is `<TypeArgs> {` ⇒ generic literal, and it is unambiguous
// because (1) no primary expression begins with '{' (see parse_primary — there is
// no TOK_LBRACE case), so a `> {` sequence can never be a valid comparison
// continuation; and (2) a type-argument list contains ONLY the tokens parse_type
// can consume. So we accept the form iff every token between the angle brackets is
// type-legal AND the balanced '>' is immediately followed by '{'. Any other token
// (a literal, an operator, a newline — anything a type cannot contain) proves this
// '<' is a comparison and we bail. False positives are therefore impossible for
// well-formed types; a malformed type-ish span at worst yields a parse error in
// parse_type, never a silent miscompile.
//
// LOAD-BEARING INVARIANT: this rests on "no expression begins with '{'". If Ember
// ever gains brace-initial expressions (map/record literals, block-expressions),
// `> {` stops being unambiguous and OFI-002 must be reopened — that is the point of
// stating it here. See docs/grammar.ebnf and docs/language.md.

// type_arg_token reports whether `t` can appear inside a type-argument list, i.e.
// whether parse_type could consume it. This is the exact token set of the type
// grammar: names + qualification (`mod.Type`), nested generics (`<`/`>`), the arg
// separator (`,`), array types (`[T]`), and function types (`fn(A, B) -> R`).
static int type_arg_token(TokenType t) {
    switch (t) {
        case TOK_IDENT:                                   // type / primitive names
        case TOK_DOT:                                     // module-qualified `mod.Type`
        case TOK_COMMA:                                   // argument separator
        case TOK_LBRACKET: case TOK_RBRACKET:             // array type `[T]`
        case TOK_FN: case TOK_LPAREN: case TOK_RPAREN:    // function type `fn(A) -> R`
        case TOK_ARROW:                                   //   …its return arrow
            return 1;
        default:                                          // '<'/'>' handled by the scanner
            return 0;
    }
}

static int looks_like_generic_struct_lit_from(Parser *p, size_t start) {
    size_t i = start;    // positioned at the '<'
    int depth = 0;
    while (i < p->count) {
        TokenType t = p->toks[i].type;
        if (t == TOK_LT) {
            depth++;
        } else if (t == TOK_GT) {
            depth--;
            if (depth == 0) {
                return (i + 1 < p->count && p->toks[i + 1].type == TOK_LBRACE);
            }
        } else if (t == TOK_SHR) {
            // '>>' closes two nested type-arg lists at once (Box<Box<int>>). It counts
            // as two '>'. If that exactly closes the outer list, the form is a generic
            // literal iff a '{' follows; overshooting (depth < 0) means this '<' was a
            // comparison after all (e.g. `a < b >> c`).
            depth -= 2;
            if (depth == 0) {
                return (i + 1 < p->count && p->toks[i + 1].type == TOK_LBRACE);
            }
            if (depth < 0) {
                return 0;
            }
        } else if (!type_arg_token(t)) {
            // A token a type can't contain ⇒ this '<' is a comparison, not a
            // type-argument list. (Subsumes the old EOF/NEWLINE/brace/paren bails;
            // TOK_SHL lands here too — a '<<' can't open a type-arg list.)
            return 0;
        }
        i++;
    }
    return 0;
}

// Back-compat wrapper: the lookahead from the current '<'.
static int looks_like_generic_struct_lit(Parser *p) {
    return looks_like_generic_struct_lit_from(p, p->pos);
}

// expect_type_close consumes the '>' that closes a type-argument list. A '>>'
// (TOK_SHR) sitting here is the combined close of TWO nested generic lists, e.g.
// `Box<Box<int>>`: we split it — rewrite this token into a single '>' for the
// ENCLOSING list and do NOT advance, so the next close consumes the remaining '>'.
// This is the standard C++/Rust/Java trick that lets the shift operator and nested
// generics share the '>>' lexeme. (Parser.toks is the lexer's mutable buffer; its
// `const` is only an API contract, so rewriting the token in place is safe.)
static void expect_type_close(Parser *p) {
    if (check(p, TOK_SHR)) {
        Token *t = (Token *)&p->toks[p->pos];
        t->type    = TOK_GT;
        t->start  += 1;          // now points at the second '>' (keeps spans honest)
        t->length  = 1;
        t->col    += 1;
        return;                  // do not advance — the rewritten '>' is consumed next
    }
    expect(p, TOK_GT, "expected '>' to close type arguments");
}





// parse_struct_lit_body parses `{ field: value, … }` for an already-parsed type.
static Expr *parse_struct_lit(Parser *p, Type *type) {
    Expr *e = new_expr(p, EXPR_STRUCT_LIT);
    e->as.struct_lit.type = type;
    e->as.struct_lit.resolved_struct = -1;   // set by the checker
    e->as.struct_lit.inline_sid = -1;        // set by the checker (value-types 3b.4c)
    e->as.struct_lit.box_result = 1;         // default: box the constructed struct
    e->as.struct_lit.witnesses     = NULL;   // set by the checker for a bounded generic struct
    e->as.struct_lit.witness_total = 0;
    expect(p, TOK_LBRACE, "expected '{' to begin struct literal");
    skip_newlines(p);

    Vec fields;
    vec_init(&fields, sizeof(StructLitField));
    while (!check(p, TOK_RBRACE) && !at_end(p)) {
        StructLitField f;
        const Token *name_tok = expect(p, TOK_IDENT, "expected field name");
        f.name = tok_text(p, name_tok);
        expect(p, TOK_COLON, "expected ':' after field name");
        f.value = parse_expression(p);
        vec_push(&fields, &f);

        skip_newlines(p);
        if (match(p, TOK_COMMA)) {
            skip_newlines(p);
        }
    }
    expect(p, TOK_RBRACE, "expected '}' to close struct literal");
    e->as.struct_lit.fields = vec_to_arena(p->arena, &fields,
                                           &e->as.struct_lit.field_count);
    return e;
}





// parse_arg_list parses a parenthesised, comma-separated argument list, the opening '(' already
// consumed. Struct literals are re-enabled inside. An argument may be NAMED — `name: value` (OFI-140),
// for enum-variant construction — captured into a parallel `*out_names` array (one entry per arg, NULL
// for a positional arg); `*out_names` stays NULL when no argument was named (the common case). The
// checker enforces that named arguments are only legal for an enum variant and reorders them.
static Expr **parse_arg_list(Parser *p, size_t *count, const char ***out_names) {
    int saved = p->no_struct;
    p->no_struct = 0;

    Vec args;
    Vec names;
    vec_init(&args, sizeof(Expr *));
    vec_init(&names, sizeof(const char *));
    int any_named = 0;
    skip_newlines(p);
    if (!check(p, TOK_RPAREN)) {
        for (;;) {
            skip_newlines(p);
            const char *nm = NULL;
            if (check(p, TOK_IDENT) && pk2(p) == TOK_COLON) {   // a `name:` named argument
                nm = tok_text(p, adv(p));   // the field name
                adv(p);                     // the ':'
                skip_newlines(p);
                any_named = 1;
            }
            Expr *a = parse_expression(p);
            vec_push(&args, &a);
            vec_push(&names, &nm);
            skip_newlines(p);
            if (match(p, TOK_COMMA)) {
                skip_newlines(p);
                if (check(p, TOK_RPAREN)) {
                    break;
                }
                continue;
            }
            break;
        }
    }
    expect(p, TOK_RPAREN, "expected ')' after arguments");

    p->no_struct = saved;
    Expr **arr = vec_to_arena(p->arena, &args, count);
    size_t nc = 0;
    const char **narr = vec_to_arena(p->arena, &names, &nc);   // also releases the names Vec's buffer
    if (out_names != NULL) {
        *out_names = any_named ? narr : NULL;   // only carry names when at least one arg was named
    }
    return arr;
}





// build_string_parts splits a string literal's raw inner text into parts: decoded
// literal runs and interpolation holes `{ … }`. Escapes are resolved here (so `\{`
// is a literal brace, not a hole); a hole's contents are re-lexed and parsed as a
// full expression. Always yields at least one part (an empty string ⇒ one empty
// literal). `strtok` positions any error.
static void build_string_parts(Parser *p, const Token *strtok, const char *raw,
                               size_t rawlen, StrPart **out_parts, size_t *out_count) {
    StrPart parts[MAX_STR_PARTS];
    size_t  np = 0;
    char   *buf = arena_alloc(p->arena, rawlen + 1);   // scratch for the current run
    size_t  blen = 0;
    size_t  i = 0;
    while (i < rawlen) {
        char ch = raw[i];
        if (ch == '\\' && i + 1 < rawlen) {
            char c = raw[i + 1];
            i += 2;
            switch (c) {
                case 'n': buf[blen++] = '\n'; break;
                case 't': buf[blen++] = '\t'; break;
                case 'r': buf[blen++] = '\r'; break;
                case '0': buf[blen++] = '\0'; break;
                default:  buf[blen++] = c;    break;   // \\ \" \{ \} → literal char
            }
        } else if (ch == '{') {
            if (blen > 0 && np < MAX_STR_PARTS) {       // flush the literal run
                parts[np].expr = NULL;
                parts[np].text = arena_strndup(p->arena, buf, blen);
                parts[np].len  = blen;
                np++;
                blen = 0;
            }
            size_t j = i + 1;       // find the matching close brace (balanced),
            int depth = 1;          // skipping braces that sit inside a nested string
            while (j < rawlen) {
                char cj = raw[j];
                if (cj == '\\' && j + 1 < rawlen) {
                    j += 2;                         // escaped char
                    continue;
                }
                if (cj == '"') {                    // a nested string literal
                    j++;
                    while (j < rawlen && raw[j] != '"') {
                        if (raw[j] == '\\' && j + 1 < rawlen) j++;
                        j++;
                    }
                    if (j < rawlen) j++;            // closing quote
                    continue;
                }
                if (cj == '{') {
                    depth++;
                } else if (cj == '}') {
                    if (--depth == 0) break;
                }
                j++;
            }
            if (depth != 0) {
                error_at(p, strtok, "unterminated '{' in a string interpolation");
                break;
            }
            size_t holelen = j - (i + 1);
            if (holelen == 0) {
                error_at(p, strtok, "empty interpolation '{}'");
            } else if (np < MAX_STR_PARTS) {
                const char *hole = arena_strndup(p->arena, raw + i + 1, holelen);
                TokenList sub = lexer_scan(hole, p->src_name);
                // The hole was re-lexed standalone, so its tokens carry hole-relative positions
                // (line 1, col from the hole start). Offset them to where the hole actually sits in
                // the file, so tooling (hover, go-to-definition, semantic tokens) sees interpolated
                // identifiers at their true location instead of all bunched at line 1.
                {
                    int hl = strtok->line;
                    int hc = strtok->col + 1;             // file col of raw[0] (just past the opening ")
                    for (size_t k = 0; k <= i; k++) {     // walk to the first hole char (raw[i+1])
                        if (raw[k] == '\n') { hl++; hc = 1; } else { hc++; }
                    }
                    for (size_t t = 0; t < sub.count; t++) {
                        if (sub.tokens[t].line == 1) {
                            sub.tokens[t].col = hc + (sub.tokens[t].col - 1);
                        }
                        sub.tokens[t].line = hl + (sub.tokens[t].line - 1);
                    }
                }
                const Token *save_t = p->toks;
                size_t save_pos = p->pos;
                int save_ns = p->no_struct;
                p->toks = sub.tokens;
                p->pos = 0;
                p->no_struct = 0;
                Expr *hexpr = parse_expression(p);
                int leftover = (pk(p) != TOK_EOF);
                p->toks = save_t;
                p->pos = save_pos;
                p->no_struct = save_ns;
                if (sub.had_error || leftover) {
                    error_at(p, strtok, "invalid expression in a string interpolation");
                }
                token_list_free(&sub);
                parts[np].expr = hexpr;
                parts[np].text = NULL;
                parts[np].len  = 0;
                parts[np].render_kind = 0;   // set by the checker from the hole type
                parts[np].string_temp = 0;   // set by the checker (owned-temp string hole)
                np++;
            }
            i = j + 1;
        } else {
            buf[blen++] = ch;
            i++;
        }
    }
    if ((blen > 0 || np == 0) && np < MAX_STR_PARTS) {  // trailing run (or empty string)
        parts[np].expr = NULL;
        parts[np].text = arena_strndup(p->arena, buf, blen);
        parts[np].len  = blen;
        np++;
    }
    StrPart *arr = arena_alloc(p->arena, np * sizeof(StrPart));
    memcpy(arr, parts, np * sizeof(StrPart));
    *out_parts = arr;
    *out_count = np;
}





// parse_lambda parses `|params| body`, where each parameter is `name` (type
// inferred from context) or `name: type`, and the body is either a `{ … }` block
// or a single expression (wrapped as one `return`). A zero-parameter lambda needs a
// space — `| |` — because `||` lexes as logical or.
static Expr *parse_lambda(Parser *p) {
    Expr *e = new_expr(p, EXPR_LAMBDA);
    expect(p, TOK_PIPE, "expected '|' to begin lambda parameters");
    Vec params;
    vec_init(&params, sizeof(Param));
    if (!check(p, TOK_PIPE)) {
        for (;;) {
            Param param;
            param.qual            = OWN_NONE;
            param.is_self         = 0;
            param.name            = NULL;
            param.type            = NULL;   // NULL ⇒ inferred from the expected fn type
            param.release_at_exit = 0;
            param.inline_struct_id = -1;    // set by the checker (value-types 3b.4)
            const Token *name = expect(p, TOK_IDENT,
                                       "expected a lambda parameter name");
            param.name = tok_text(p, name);
            if (match(p, TOK_COLON)) {
                param.type = parse_type(p);
            }
            vec_push(&params, &param);
            if (match(p, TOK_COMMA)) {
                continue;
            }
            break;
        }
    }
    expect(p, TOK_PIPE, "expected '|' to close lambda parameters");
    e->as.lambda.params = vec_to_arena(p->arena, &params, &e->as.lambda.param_count);
    e->as.lambda.lifted_fn_index = -1;
    e->as.lambda.capture_count   = 0;

    if (check(p, TOK_LBRACE)) {
        e->as.lambda.body = parse_block(p);
    } else {
        // Expression body: wrap as a single `return <expr>` so the lambda body is a
        // uniform block, liftable to a real function exactly like any other.
        Expr *body_expr = parse_expression(p);
        Stmt *ret = new_stmt(p, STMT_RETURN);
        ret->as.ret.value = body_expr;
        Stmt **stmts = arena_alloc(p->arena, sizeof(Stmt *));
        stmts[0] = ret;
        e->as.lambda.body.stmts = stmts;
        e->as.lambda.body.count = 1;
    }
    return e;
}


static Expr *parse_primary(Parser *p) {
    switch (pk(p)) {
        case TOK_PIPE:
            return parse_lambda(p);
        // For leaves, new_expr is called BEFORE adv so the node records the
        // literal's own position, not the following token's (which would
        // mis-map the execution tape's source lines).
        case TOK_INT: {
            Expr *e = new_expr(p, EXPR_INT);
            const Token *t = adv(p);
            errno = 0;
            // Parse the magnitude as UNSIGNED 64-bit so a full-range `u64` literal (up to 2⁶⁴−1)
            // survives to the checker, which alone knows the literal's TYPE (OFI-123). The bits are
            // stored in the signed int_lit slot — a magnitude > i64-max lands with the sign bit set,
            // which the checker reads as "u64-only" (int_fits). The narrower-than-i64 range checks
            // (and the "not in u64 context" error) are the checker's job, not the parser's. strtoull
            // stops at the width suffix (e.g. `255u8`); the lexeme carries no sign (`-` is its own token).
            unsigned long long uv = strtoull(t->start, NULL, 10);
            if (errno == ERANGE) {
                // The digits overflow even 64 bits (> 2⁶⁴−1) — no integer type can hold it.
                error_at(p, t, "integer literal is out of range (larger than u64 / 2^64-1)");
            }
            e->as.int_lit = (long long)uv;
            // A width suffix follows the digits in the lexeme (e.g. `255u8`).
            size_t i = 0;
            while (i < t->length && t->start[i] >= '0' && t->start[i] <= '9') {
                i++;
            }
            if (i < t->length) {
                int code = suffix_code(t->start + i, t->length - i);
                if (code == 0) {
                    error_at(p, t, "unknown integer width suffix "
                                   "(use i8/i16/i32/i64/u8/u16/u32/u64)");
                } else {
                    e->suffix_type = code;
                }
            }
            return e;
        }
        case TOK_FLOAT: {
            Expr *e = new_expr(p, EXPR_FLOAT);
            const Token *t = adv(p);
            e->as.float_lit = strtod(t->start, NULL);
            return e;
        }
        case TOK_STRING: {
            Expr *e = new_expr(p, EXPR_STRING);
            const Token *t = adv(p);
            size_t inner = t->length >= 2 ? t->length - 2 : 0;
            build_string_parts(p, t, t->start + 1, inner,
                               &e->as.str.parts, &e->as.str.part_count);
            return e;
        }
        case TOK_TRUE:
        case TOK_FALSE: {
            Expr *e = new_expr(p, EXPR_BOOL);
            e->as.bool_lit = (pk(p) == TOK_TRUE);
            adv(p);
            return e;
        }
        case TOK_SELF: {
            Expr *e = new_expr(p, EXPR_IDENT);
            adv(p);
            e->as.ident = "self";
            return e;
        }
        case TOK_IDENT: {
            const Token *t = adv(p);
            const char *name = tok_text(p, t);
            // Qualified struct literal from another module: `mod.Type { … }` or
            // `mod.Type<…> { … }`. Detected by lookahead so a plain qualified
            // reference (`mod.foo(…)`, `mod.C < x`) is left to the normal path.
            if (!p->no_struct && pk(p) == TOK_DOT &&
                p->pos + 1 < p->count && p->toks[p->pos + 1].type == TOK_IDENT &&
                p->pos + 2 < p->count &&
                (p->toks[p->pos + 2].type == TOK_LBRACE ||
                 (p->toks[p->pos + 2].type == TOK_LT &&
                  looks_like_generic_struct_lit_from(p, p->pos + 2)))) {
                adv(p);                                  // '.'
                const Token *tn = adv(p);                // the type name
                const char *tname = tok_text(p, tn);
                if (check(p, TOK_LBRACE)) {
                    Type *ty = new_type(p, TYPE_NAME);
                    ty->as.name.qualifier = name;
                    ty->as.name.name = tname;
                    return parse_struct_lit(p, ty);
                }
                Type *ty = new_type(p, TYPE_GENERIC);
                ty->as.generic.qualifier = name;
                ty->as.generic.name = tname;
                adv(p);                                  // '<'
                Vec gargs;
                vec_init(&gargs, sizeof(Type *));
                for (;;) {
                    Type *a = parse_type(p);
                    vec_push(&gargs, &a);
                    if (match(p, TOK_COMMA)) {
                        continue;
                    }
                    break;
                }
                expect_type_close(p);
                ty->as.generic.args = vec_to_arena(p->arena, &gargs,
                                                   &ty->as.generic.arg_count);
                return parse_struct_lit(p, ty);
            }
            if (!p->no_struct && check(p, TOK_LBRACE)) {
                Type *ty = new_type(p, TYPE_NAME);
                ty->as.name.name = name;
                return parse_struct_lit(p, ty);
            }
            if (!p->no_struct && check(p, TOK_LT) &&
                looks_like_generic_struct_lit(p)) {
                Type *ty = new_type(p, TYPE_GENERIC);
                ty->as.generic.name = name;
                adv(p); // '<'
                Vec gargs;
                vec_init(&gargs, sizeof(Type *));
                for (;;) {
                    Type *a = parse_type(p);
                    vec_push(&gargs, &a);
                    if (match(p, TOK_COMMA)) {
                        continue;
                    }
                    break;
                }
                expect_type_close(p);
                ty->as.generic.args = vec_to_arena(p->arena, &gargs,
                                                   &ty->as.generic.arg_count);
                return parse_struct_lit(p, ty);
            }
            Expr *e = new_expr(p, EXPR_IDENT);
            e->line = t->line;   // the ident token, not the post-lookahead cursor
            e->col  = t->col;
            e->as.ident = name;
            return e;
        }
        case TOK_LPAREN: {
            adv(p);
            int saved = p->no_struct;
            p->no_struct = 0;
            skip_newlines(p);
            Expr *inner = parse_expression(p);
            skip_newlines(p);
            expect(p, TOK_RPAREN, "expected ')' to close grouping");
            p->no_struct = saved;
            return inner;
        }
        case TOK_LBRACKET: {
            Expr *e = new_expr(p, EXPR_ARRAY);
            e->as.array.elem_struct_id = -1;   // checker upgrades to a struct id if inline
            adv(p);
            int saved = p->no_struct;
            p->no_struct = 0;
            Vec elems;
            vec_init(&elems, sizeof(Expr *));
            skip_newlines(p);
            if (!check(p, TOK_RBRACKET)) {
                for (;;) {
                    skip_newlines(p);
                    Expr *el = parse_expression(p);
                    vec_push(&elems, &el);
                    skip_newlines(p);
                    if (match(p, TOK_COMMA)) {
                        skip_newlines(p);
                        if (check(p, TOK_RBRACKET)) {
                            break;
                        }
                        continue;
                    }
                    break;
                }
            }
            expect(p, TOK_RBRACKET, "expected ']' to close array literal");
            e->as.array.elems = vec_to_arena(p->arena, &elems, &e->as.array.count);
            p->no_struct = saved;
            return e;
        }
        default:
            error_at(p, cur(p), "expected an expression");
            if (!at_end(p)) {
                adv(p); // guarantee progress
            }
            return NULL;
    }
}





static Expr *parse_postfix(Parser *p) {
    Expr *e = parse_primary(p);
    if (e == NULL) {
        return NULL;
    }
    for (;;) {
        // Postfix wrappers take their position from the object (the start of the
        // whole expression), not the cursor after the operator.
        if (match(p, TOK_DOT)) {
            const Token *name_tok = expect(p, TOK_IDENT,
                                           "expected name after '.'");
            Expr *get = new_expr(p, EXPR_GET);
            get->line = e->line;
            get->col  = e->col;
            get->as.get.object       = e;
            get->as.get.name         = tok_text(p, name_tok);
            get->as.get.name_line    = name_tok->line;   // position of `.field` for tooling
            get->as.get.name_col     = name_tok->col;
            get->as.get.field_index  = -1;   // resolved by the checker
            get->as.get.inline_struct_id = -1;   // nested inline-struct field sid (checker-set); 0 is valid
            get->as.get.bound_method = -1;   // set if it is a bound-method call
            get->as.get.bound_witness = 0;   // witness local/field (set by the checker)
            get->as.get.bound_via_self = 0;  // set if the witness is read from a self field
            get->as.get.dyn_method   = -1;   // set if it is a dynamic interface-method call
            get->as.get.array_op     = 0;    // set if it is an array intrinsic
            get->as.get.string_op    = 0;    // set if it is a string intrinsic
            get->as.get.clone_op     = 0;    // set if it is a `.clone()` deep copy (OFI-082)
            e = get;
        } else if (match(p, TOK_LPAREN)) {
            Expr *call = new_expr(p, EXPR_CALL);
            call->line = e->line;
            call->col  = e->col;
            call->as.call.callee        = e;
            call->as.call.arg_names     = NULL;   // set by parse_arg_list iff a `name:` arg appears (OFI-140)
            call->as.call.args          = parse_arg_list(p, &call->as.call.arg_count,
                                                         &call->as.call.arg_names);
            call->as.call.witnesses     = NULL;   // set if it is a bounded call
            call->as.call.witness_total = 0;
            call->as.call.resolved_fn   = -1;     // set by the checker for direct calls
            call->as.call.mono_arg_count = 0;     // set by the checker for generic calls
            call->as.call.ret_struct_id = -1;     // set by the checker (value-types 3b.4b)
            call->as.call.box_result    = 1;      // default: box a multi-slot result
            call->as.call.cextern_index = -1;     // set by the checker for an extern "c" call (§5h)
            call->as.call.cextern_ret_sid = -1;   // set by the checker for a struct-returning extern
            call->as.call.extern_direct = 0;      // OFI-167: set by the checker for a native direct-extern
            call->as.call.extern_cname  = NULL;
            call->as.call.newtype_ctor  = 0;
            call->as.call.refinement    = NULL;
            e = call;
        } else if (match(p, TOK_LBRACKET)) {
            int saved = p->no_struct;
            p->no_struct = 0;
            Expr *idx = parse_expression(p);
            expect(p, TOK_RBRACKET, "expected ']' after index");
            p->no_struct = saved;
            Expr *index = new_expr(p, EXPR_INDEX);
            index->line = e->line;
            index->col  = e->col;
            index->as.index.object = e;
            index->as.index.index  = idx;
            index->as.index.inline_struct_id = -1;   // checker stamps it for an inline-struct elem
            e = index;
        } else if (match(p, TOK_QUESTION)) {
            Expr *tryx = new_expr(p, EXPR_TRY);
            tryx->line = e->line;
            tryx->col  = e->col;
            tryx->as.try_.operand = e;
            tryx->as.try_.success_variant = -1;   // set by the checker
            e = tryx;
        } else {
            break;
        }
    }
    return e;
}





static Expr *parse_unary(Parser *p) {
    // Every expression operand and every parenthesised/bracketed re-entry passes through
    // here, and the unary `-`/`!`/`~` chain recurses directly, so this one guard bounds all
    // expression-nesting depth (see MAX_PARSE_DEPTH). NULL propagates cleanly upward.
    if (++p->depth > MAX_PARSE_DEPTH) {
        error_at(p, cur(p), "expression nests too deeply");
        p->depth--;
        return NULL;
    }
    Expr *result;
    if (check(p, TOK_BANG) || check(p, TOK_MINUS) || check(p, TOK_TILDE)) {
        Expr *e = new_expr(p, EXPR_UNARY);   // position of the operator
        TokenType op = pk(p);
        adv(p);
        e->as.unary.op      = op;
        e->as.unary.operand = parse_unary(p);
        result = e;
    } else {
        result = parse_postfix(p);
    }
    p->depth--;
    return result;
}





static Expr *parse_binary(Parser *p, int min_prec) {
    Expr *left = parse_unary(p);
    if (left == NULL) {
        return NULL;
    }
    for (;;) {
        int prec = binary_prec(pk(p));
        if (prec == 0 || prec < min_prec) {
            break;
        }
        TokenType op = pk(p);
        adv(p);
        Expr *right = parse_binary(p, prec + 1);
        Expr *e = new_expr(p, EXPR_BINARY);
        e->line = left->line;   // the expression starts at its left operand
        e->col  = left->col;
        e->as.binary.op    = op;
        e->as.binary.left  = left;
        e->as.binary.right = right;
        left = e;
    }
    return left;
}





static Expr *parse_expression(Parser *p) {
    Expr *e = parse_binary(p, 1);
    // `a .. b` — an exclusive integer range, lowest precedence (its bounds are
    // full expressions). Only meaningful as a `for` iterator; the checker enforces
    // that. No chaining: `a..b..c` is rejected there.
    if (check(p, TOK_DOTDOT)) {
        Expr *range = new_expr(p, EXPR_RANGE);
        adv(p);
        range->as.range.lo = e;
        range->as.range.hi = parse_binary(p, 1);
        return range;
    }
    return e;
}





// ---- Patterns and statements. ----

static Pattern parse_pattern(Parser *p) {
    Pattern pat;
    pat.type_name     = NULL;
    pat.bindings      = NULL;
    pat.binding_count = 0;
    pat.wildcard      = 0;
    pat.enum_id       = -1;   // checker stamps the resolved enum id + tag (0 is valid, so -1 default)
    pat.variant_index = -1;
    pat.line          = cur(p)->line;
    pat.col           = cur(p)->col;
    for (int b = 0; b < 16; b++) {
        pat.binding_struct[b] = -1;   // checker stamps an all-scalar value-struct payload's sid
    }

    const Token *first = expect(p, TOK_IDENT, "expected a pattern name");
    pat.variant = tok_text(p, first);
    if (strcmp(pat.variant, "_") == 0) {
        pat.wildcard = 1;   // a catch-all arm: no qualifier, no bindings
        return pat;
    }
    if (match(p, TOK_DOT)) {
        pat.type_name = pat.variant;
        const Token *v = expect(p, TOK_IDENT, "expected variant name after '.'");
        pat.variant = tok_text(p, v);
    }

    if (match(p, TOK_LPAREN)) {
        Vec binds;
        vec_init(&binds, sizeof(const char *));
        if (!check(p, TOK_RPAREN)) {
            for (;;) {
                const Token *b = expect(p, TOK_IDENT, "expected a binding name");
                const char *name = tok_text(p, b);
                vec_push(&binds, &name);
                if (match(p, TOK_COMMA)) {
                    continue;
                }
                break;
            }
        }
        expect(p, TOK_RPAREN, "expected ')' to close pattern bindings");
        pat.bindings = vec_to_arena(p->arena, &binds, &pat.binding_count);
    }
    return pat;
}





static Block parse_block(Parser *p) {
    Block block;
    expect(p, TOK_LBRACE, "expected '{' to begin a block");
    skip_newlines(p);

    Vec stmts;
    vec_init(&stmts, sizeof(Stmt *));
    while (!check(p, TOK_RBRACE) && !at_end(p)) {
        size_t before = p->pos;
        Stmt *s = parse_statement(p);
        if (s != NULL) {
            vec_push(&stmts, &s);
        }
        if (p->panic) {
            synchronize(p);
        }
        if (p->pos == before) {
            adv(p); // guarantee progress on a stuck error
        }
        skip_newlines(p);
    }
    expect(p, TOK_RBRACE, "expected '}' to close a block");
    block.stmts = vec_to_arena(p->arena, &stmts, &block.count);
    return block;
}





// parse_cond parses an expression in a context where a trailing '{' begins a
// block (if/for/match), so struct literals are disabled for the duration.
static Expr *parse_cond(Parser *p) {
    int saved = p->no_struct;
    p->no_struct = 1;
    Expr *e = parse_expression(p);
    p->no_struct = saved;
    return e;
}





static Stmt *parse_if(Parser *p) {
    Stmt *s = new_stmt(p, STMT_IF);
    adv(p); // 'if'
    s->as.if_.cond     = parse_cond(p);
    s->as.if_.then_blk = parse_block(p);
    s->as.if_.else_branch = NULL;

    skip_newlines(p);
    if (match(p, TOK_ELSE)) {
        if (check(p, TOK_IF)) {
            s->as.if_.else_branch = parse_if(p);
        } else {
            Stmt *else_block = new_stmt(p, STMT_BLOCK);
            else_block->as.block.body = parse_block(p);
            s->as.if_.else_branch = else_block;
        }
    }
    return s;
}





static Stmt *parse_let(Parser *p, int is_var) {
    Stmt *s = new_stmt(p, STMT_LET);
    adv(p); // 'let' or 'var'
    s->as.let.is_var = is_var;
    s->as.let.drop_at_scope_end = 0;   // set by the checker once move-state is known
    s->as.let.inline_struct_id = -1;   // checker upgrades for an all-scalar struct binding
    s->as.let.scalar_kind = -1;        // checker upgrades for a sized numeric binding (OFI-123)
    const Token *name = expect(p, TOK_IDENT, "expected a binding name");
    s->as.let.name = tok_text(p, name);
    s->as.let.type = NULL;
    if (match(p, TOK_COLON)) {
        s->as.let.type = parse_type(p);
    }
    expect(p, TOK_ASSIGN, "expected '=' in binding");
    s->as.let.value = parse_expression(p);
    return s;
}





static Stmt *parse_statement(Parser *p) {
    switch (pk(p)) {
        case TOK_LET:
            return parse_let(p, 0);
        case TOK_VAR:
            return parse_let(p, 1);
        case TOK_IF:
            return parse_if(p);
        case TOK_RETURN: {
            Stmt *s = new_stmt(p, STMT_RETURN);
            adv(p);
            if (check(p, TOK_NEWLINE) || check(p, TOK_RBRACE) || at_end(p)) {
                s->as.ret.value = NULL;
            } else {
                s->as.ret.value = parse_expression(p);
            }
            return s;
        }
        case TOK_FOR: {
            Stmt *s = new_stmt(p, STMT_FOR);
            adv(p);
            s->as.for_.index_var = NULL;
            // `for (i, x) in array` — index and element together (arrays only).
            if (match(p, TOK_LPAREN)) {
                const Token *iv = expect(p, TOK_IDENT,
                                         "expected the index variable in 'for (i, x)'");
                s->as.for_.index_var = tok_text(p, iv);
                expect(p, TOK_COMMA, "expected ',' between the index and element");
                const Token *ev = expect(p, TOK_IDENT,
                                         "expected the element variable in 'for (i, x)'");
                s->as.for_.var = tok_text(p, ev);
                expect(p, TOK_RPAREN, "expected ')' after 'for (i, x)'");
            } else {
                const Token *var = expect(p, TOK_IDENT, "expected loop variable");
                s->as.for_.var = tok_text(p, var);
            }
            expect(p, TOK_IN, "expected 'in' in for-loop");
            s->as.for_.iter = parse_cond(p);
            s->as.for_.body = parse_block(p);
            return s;
        }
        case TOK_LOOP: {
            Stmt *s = new_stmt(p, STMT_LOOP);
            adv(p);
            s->as.loop.body = parse_block(p);
            return s;
        }
        case TOK_BREAK: {
            Stmt *s = new_stmt(p, STMT_BREAK);
            adv(p);
            return s;
        }
        case TOK_CONTINUE: {
            Stmt *s = new_stmt(p, STMT_CONTINUE);
            adv(p);
            return s;
        }
        case TOK_MATCH: {
            Stmt *s = new_stmt(p, STMT_MATCH);
            adv(p);
            s->as.match.value = parse_cond(p);
            expect(p, TOK_LBRACE, "expected '{' to begin match body");
            skip_newlines(p);
            Vec cases;
            vec_init(&cases, sizeof(MatchCase));
            while (!check(p, TOK_RBRACE) && !at_end(p)) {
                expect(p, TOK_CASE, "expected 'case' in match");
                MatchCase mc;
                mc.pattern = parse_pattern(p);
                mc.body    = parse_block(p);
                vec_push(&cases, &mc);
                if (p->panic) {
                    synchronize(p);
                }
                skip_newlines(p);
            }
            expect(p, TOK_RBRACE, "expected '}' to close match body");
            s->as.match.cases = vec_to_arena(p->arena, &cases,
                                             &s->as.match.case_count);
            return s;
        }
        case TOK_SPAWN: {
            Stmt *s = new_stmt(p, STMT_SPAWN);
            adv(p);
            s->as.spawn.call = parse_expression(p);
            return s;
        }
        case TOK_NURSERY: {
            Stmt *s = new_stmt(p, STMT_NURSERY);
            adv(p);
            s->as.nursery.body = parse_block(p);
            return s;
        }
        case TOK_LBRACE: {
            Stmt *s = new_stmt(p, STMT_BLOCK);
            s->as.block.body = parse_block(p);
            return s;
        }
        default: {
            Expr *e = parse_expression(p);
            if (e == NULL) {
                return NULL;
            }
            if (match(p, TOK_ASSIGN)) {
                Stmt *s = new_stmt(p, STMT_ASSIGN);
                s->as.assign.target = e;
                s->as.assign.value  = parse_expression(p);
                return s;
            }
            Stmt *s = new_stmt(p, STMT_EXPR);
            s->as.expr.expr = e;
            return s;
        }
    }
}





// ---- Declarations. ----

static GenericParam *parse_generics(Parser *p, size_t *count) {
    if (!match(p, TOK_LT)) {
        *count = 0;
        return NULL;
    }
    Vec params;
    vec_init(&params, sizeof(GenericParam));
    for (;;) {
        GenericParam g;
        const Token *name = expect(p, TOK_IDENT, "expected generic parameter name");
        g.name        = tok_text(p, name);
        g.bound_count = 0;
        g.is_copy     = 0;
        if (match(p, TOK_COLON)) {
            // One or more `+`-separated bounds. `Copy` is the contextual copyable
            // marker (sets is_copy); any other name is an interface bound (collected).
            for (;;) {
                const Token *b = expect(p, TOK_IDENT, "expected an interface or 'Copy' bound");
                const char *bn = tok_text(p, b);
                if (strcmp(bn, "Copy") == 0) {
                    g.is_copy = 1;
                } else if (g.bound_count < MAX_BOUNDS) {
                    g.bounds[g.bound_count++] = bn;
                } else {
                    error_at(p, b, "too many interface bounds on one type parameter");
                }
                if (match(p, TOK_PLUS)) {
                    continue;
                }
                break;
            }
        }
        vec_push(&params, &g);
        if (match(p, TOK_COMMA)) {
            continue;
        }
        break;
    }
    expect(p, TOK_GT, "expected '>' to close generic parameters");
    return vec_to_arena(p->arena, &params, count);
}





static Param *parse_params(Parser *p, size_t *count) {
    expect(p, TOK_LPAREN, "expected '(' before parameters");
    Vec params;
    vec_init(&params, sizeof(Param));
    skip_newlines(p);
    if (!check(p, TOK_RPAREN)) {
        for (;;) {
            skip_newlines(p);
            Param param;
            param.qual            = OWN_NONE;
            param.is_self         = 0;
            param.name            = NULL;
            param.type            = NULL;
            param.release_at_exit = 0;   // set by the checker for refcounted params
            param.inline_struct_id = -1; // set by the checker (value-types 3b.4)

            // The ownership qualifier comes before the binding, uniformly for
            // the `self` receiver and for named parameters (MANIFESTO §5b): it
            // describes how the parameter relates to the argument, not the type.
            if (match(p, TOK_MUT)) {
                param.qual = OWN_MUT;
            } else if (match(p, TOK_MOVE)) {
                param.qual = OWN_MOVE;
            }

            if (check(p, TOK_SELF)) {
                adv(p);
                param.is_self = 1;
            } else {
                const Token *name = expect(p, TOK_IDENT, "expected parameter name");
                param.name = tok_text(p, name);
                expect(p, TOK_COLON, "expected ':' after parameter name");
                param.type = parse_type(p);
            }
            vec_push(&params, &param);

            skip_newlines(p);
            if (match(p, TOK_COMMA)) {
                skip_newlines(p);
                if (check(p, TOK_RPAREN)) {
                    break;
                }
                continue;
            }
            break;
        }
    }
    expect(p, TOK_RPAREN, "expected ')' after parameters");
    return vec_to_arena(p->arena, &params, count);
}





static FnDecl parse_fn(Parser *p, int with_body) {
    FnDecl fn;
    fn.line = cur(p)->line;
    fn.col  = cur(p)->col;
    fn.src_path = NULL;   // OFI-111a: a normal fn maps to its module via module_of_decl; only a
                          // lifted lambda overrides this (it lands outside the module ranges).
    fn.doc  = tok_doc(p, cur(p));   // doc rides on the `fn` keyword token
    adv(p); // 'fn'
    const Token *name = expect(p, TOK_IDENT, "expected function name");
    fn.name        = tok_text(p, name);
    fn.generics    = parse_generics(p, &fn.generic_count);
    fn.params      = parse_params(p, &fn.param_count);
    fn.return_type = NULL;
    fn.ret_struct_id = -1;   // set by the checker (value-types 3b.4b)
    if (match(p, TOK_ARROW)) {
        fn.return_type = parse_type(p);
    }
    fn.requires_clauses = NULL;
    fn.requires_count   = 0;
    fn.ensures_clauses  = NULL;
    fn.ensures_count    = 0;
    fn.has_body = with_body;
    if (with_body) {
        // Contract clauses (MANIFESTO §5e): `requires <expr>` / `ensures <expr>`,
        // any number in any order, between the signature and the `{` body. They sit
        // on their own lines, so skip the significant newlines around them. (Only
        // bodied functions carry contracts; an interface signature's trailing
        // newline separates declarations and must not be eaten here.)
        Vec reqs;
        Vec enss;
        vec_init(&reqs, sizeof(Expr *));
        vec_init(&enss, sizeof(Expr *));
        skip_newlines(p);
        while (check(p, TOK_REQUIRES) || check(p, TOK_ENSURES)) {
            int is_req = check(p, TOK_REQUIRES);
            adv(p);                   // 'requires' / 'ensures'
            Expr *cond = parse_expression(p);
            vec_push(is_req ? &reqs : &enss, &cond);
            skip_newlines(p);
        }
        fn.requires_clauses = vec_to_arena(p->arena, &reqs, &fn.requires_count);
        fn.ensures_clauses  = vec_to_arena(p->arena, &enss, &fn.ensures_count);
        fn.body = parse_block(p);
    } else {
        fn.body.stmts = NULL;
        fn.body.count = 0;
    }
    return fn;
}





// parse_implements parses an optional `implements A, B, C` clause (nominal
// conformance — MANIFESTO §5b). Returns the interface names, or NULL if absent.
static const char **parse_implements(Parser *p, size_t *count) {
    if (!match(p, TOK_IMPLEMENTS)) {
        *count = 0;
        return NULL;
    }
    Vec names;
    vec_init(&names, sizeof(const char *));
    for (;;) {
        const Token *n = expect(p, TOK_IDENT,
                                "expected an interface name after 'implements'");
        const char *name = tok_text(p, n);
        vec_push(&names, &name);
        if (match(p, TOK_COMMA)) {
            continue;
        }
        break;
    }
    return vec_to_arena(p->arena, &names, count);
}





static Decl *parse_struct(Parser *p) {
    Decl *d = arena_alloc(p->arena, sizeof(Decl));
    d->kind = DECL_STRUCT;
    d->line = cur(p)->line;
    d->col  = cur(p)->col;
    d->doc  = tok_doc(p, cur(p));
    d->as.struct_.is_rc = 0;   // arena nodes are not zeroed; the `rc` modifier (parse_decl) sets it
    d->as.struct_.is_resource = 0;   // likewise the `resource` modifier (parse_decl) sets it
    adv(p); // 'struct'
    const Token *name = expect(p, TOK_IDENT, "expected struct name");
    d->as.struct_.name     = tok_text(p, name);
    d->as.struct_.generics = parse_generics(p, &d->as.struct_.generic_count);
    d->as.struct_.implements =
        parse_implements(p, &d->as.struct_.implements_count);
    expect(p, TOK_LBRACE, "expected '{' to begin struct body");
    skip_newlines(p);

    Vec fields;
    Vec methods;
    vec_init(&fields, sizeof(Field));
    vec_init(&methods, sizeof(FnDecl));
    while (!check(p, TOK_RBRACE) && !at_end(p)) {
        if (check(p, TOK_FN)) {
            FnDecl m = parse_fn(p, 1);
            vec_push(&methods, &m);
        } else {
            Field f;
            const Token *fname = expect(p, TOK_IDENT, "expected field name");
            f.name = tok_text(p, fname);
            f.doc  = tok_doc(p, fname);
            f.line = fname->line;
            f.col  = fname->col;
            expect(p, TOK_COLON, "expected ':' after field name");
            f.type = parse_type(p);
            vec_push(&fields, &f);
        }
        if (p->panic) {
            synchronize(p);
        }
        skip_newlines(p);
    }
    expect(p, TOK_RBRACE, "expected '}' to close struct body");
    d->as.struct_.fields  = vec_to_arena(p->arena, &fields,
                                         &d->as.struct_.field_count);
    d->as.struct_.methods = vec_to_arena(p->arena, &methods,
                                         &d->as.struct_.method_count);
    return d;
}





static Decl *parse_enum(Parser *p) {
    Decl *d = arena_alloc(p->arena, sizeof(Decl));
    d->kind = DECL_ENUM;
    d->line = cur(p)->line;
    d->col  = cur(p)->col;
    d->doc  = tok_doc(p, cur(p));
    adv(p); // 'enum'
    const Token *name = expect(p, TOK_IDENT, "expected enum name");
    d->as.enum_.name     = tok_text(p, name);
    d->as.enum_.generics = parse_generics(p, &d->as.enum_.generic_count);
    d->as.enum_.implements =
        parse_implements(p, &d->as.enum_.implements_count);
    expect(p, TOK_LBRACE, "expected '{' to begin enum body");
    skip_newlines(p);

    Vec variants;
    vec_init(&variants, sizeof(Variant));
    while (!check(p, TOK_RBRACE) && !at_end(p)) {
        Variant v;
        const Token *vname = expect(p, TOK_IDENT, "expected variant name");
        v.name = tok_text(p, vname);
        v.doc  = tok_doc(p, vname);
        v.fields = NULL;
        v.field_count = 0;
        if (match(p, TOK_LPAREN)) {
            Vec vfields;
            vec_init(&vfields, sizeof(Field));
            if (!check(p, TOK_RPAREN)) {
                for (;;) {
                    Field f;
                    const Token *fn = expect(p, TOK_IDENT, "expected field name");
                    f.name = tok_text(p, fn);
                    f.doc  = tok_doc(p, fn);
                    f.line = fn->line;
                    f.col  = fn->col;
                    expect(p, TOK_COLON, "expected ':' after field name");
                    f.type = parse_type(p);
                    vec_push(&vfields, &f);
                    if (match(p, TOK_COMMA)) {
                        continue;
                    }
                    break;
                }
            }
            expect(p, TOK_RPAREN, "expected ')' after variant fields");
            v.fields = vec_to_arena(p->arena, &vfields, &v.field_count);
        }
        vec_push(&variants, &v);
        if (p->panic) {
            synchronize(p);
        }
        skip_newlines(p);
    }
    expect(p, TOK_RBRACE, "expected '}' to close enum body");
    d->as.enum_.variants = vec_to_arena(p->arena, &variants,
                                        &d->as.enum_.variant_count);
    return d;
}





static Decl *parse_interface(Parser *p) {
    Decl *d = arena_alloc(p->arena, sizeof(Decl));
    d->kind = DECL_INTERFACE;
    d->line = cur(p)->line;
    d->col  = cur(p)->col;
    d->doc  = tok_doc(p, cur(p));
    adv(p); // 'interface'
    const Token *name = expect(p, TOK_IDENT, "expected interface name");
    d->as.interface.name     = tok_text(p, name);
    d->as.interface.generics = parse_generics(p, &d->as.interface.generic_count);
    expect(p, TOK_LBRACE, "expected '{' to begin interface body");
    skip_newlines(p);

    Vec methods;
    vec_init(&methods, sizeof(FnDecl));
    while (!check(p, TOK_RBRACE) && !at_end(p)) {
        if (check(p, TOK_FN)) {
            FnDecl m = parse_fn(p, 0);
            vec_push(&methods, &m);
        } else {
            error_at(p, cur(p), "expected a method signature");
            synchronize(p);
        }
        skip_newlines(p);
    }
    expect(p, TOK_RBRACE, "expected '}' to close interface body");
    d->as.interface.methods = vec_to_arena(p->arena, &methods,
                                           &d->as.interface.method_count);
    return d;
}





// parse_extern parses `extern "c" { fn name(params) -> ret … }` — a block of foreign (C)
// function signatures (no bodies). Each is checked against the in-tree C registry (§5h).
static Decl *parse_extern(Parser *p) {
    Decl *d = arena_alloc(p->arena, sizeof(Decl));
    d->kind = DECL_EXTERN;
    d->line = cur(p)->line;
    d->col  = cur(p)->col;
    d->doc  = tok_doc(p, cur(p));
    adv(p); // 'extern'
    const Token *abi = expect(p, TOK_STRING,
                              "expected an ABI string after 'extern' (e.g. \"c\")");
    size_t inner = abi->length >= 2 ? abi->length - 2 : 0;
    d->as.extern_.abi = arena_strndup(p->arena, abi->start + 1, inner);
    expect(p, TOK_LBRACE, "expected '{' to begin extern block");
    skip_newlines(p);
    Vec fns;
    vec_init(&fns, sizeof(FnDecl));
    while (!check(p, TOK_RBRACE) && !at_end(p)) {
        if (check(p, TOK_FN)) {
            FnDecl f = parse_fn(p, 0);   // signature only, no body
            vec_push(&fns, &f);
        } else {
            error_at(p, cur(p), "expected a function signature in the extern block");
            synchronize(p);
        }
        skip_newlines(p);
    }
    expect(p, TOK_RBRACE, "expected '}' to close extern block");
    d->as.extern_.fns = vec_to_arena(p->arena, &fns, &d->as.extern_.fn_count);
    return d;
}


static Decl *parse_import(Parser *p) {
    Decl *d = arena_alloc(p->arena, sizeof(Decl));
    d->kind = DECL_IMPORT;
    d->line = cur(p)->line;
    d->col  = cur(p)->col;
    d->doc  = tok_doc(p, cur(p));
    adv(p); // 'import'
    const Token *path = expect(p, TOK_STRING, "expected import path string");
    size_t inner = path->length >= 2 ? path->length - 2 : 0;
    d->as.import.path = arena_strndup(p->arena, path->start + 1, inner);
    expect(p, TOK_AS, "expected 'as' in import");
    const Token *alias = expect(p, TOK_IDENT, "expected import alias");
    d->as.import.alias = tok_text(p, alias);
    return d;
}





static Decl *parse_global_let(Parser *p, int is_var) {
    Decl *d = arena_alloc(p->arena, sizeof(Decl));
    d->kind = DECL_LET;
    d->line = cur(p)->line;
    d->col  = cur(p)->col;
    d->doc  = tok_doc(p, cur(p));
    adv(p); // 'let' or 'var'
    d->as.let.is_var = is_var;
    const Token *name = expect(p, TOK_IDENT, "expected a binding name");
    d->as.let.name = tok_text(p, name);
    d->as.let.type = NULL;
    if (match(p, TOK_COLON)) {
        d->as.let.type = parse_type(p);
    }
    expect(p, TOK_ASSIGN, "expected '=' in binding");
    d->as.let.value = parse_expression(p);
    return d;
}





static Decl *parse_decl(Parser *p) {
    // `rc` is a CONTEXTUAL modifier, not a reserved word — so `rc` stays a valid identifier
    // everywhere else (e.g. `var rc = 0`). It is special only immediately before `struct`:
    // `rc struct Name { ... }` declares a shared, deeply-immutable, refcounted struct.
    if (pk(p) == TOK_IDENT &&
        p->pos + 1 < p->count && p->toks[p->pos + 1].type == TOK_STRUCT &&
        strcmp(tok_text(p, cur(p)), "rc") == 0) {
        adv(p);                         // consume the `rc` modifier
        Decl *d = parse_struct(p);
        if (d != NULL) {
            d->as.struct_.is_rc = 1;
        }
        return d;
    }
    // `resource` is likewise a CONTEXTUAL modifier, special only immediately before `struct`:
    // `resource struct Name { … fn drop(self) { … } }` declares a uniquely-owned, drop-bearing
    // struct (OFI-122) — the owned dual of `rc`. `resource` stays a valid identifier elsewhere.
    if (pk(p) == TOK_IDENT &&
        p->pos + 1 < p->count && p->toks[p->pos + 1].type == TOK_STRUCT &&
        strcmp(tok_text(p, cur(p)), "resource") == 0) {
        adv(p);                         // consume the `resource` modifier
        Decl *d = parse_struct(p);
        if (d != NULL) {
            d->as.struct_.is_resource = 1;
        }
        return d;
    }
    switch (pk(p)) {
        case TOK_FN: {
            Decl *d = arena_alloc(p->arena, sizeof(Decl));
            d->kind = DECL_FN;
            d->line = cur(p)->line;
            d->col  = cur(p)->col;
            d->as.fn = parse_fn(p, 1);
            d->doc   = d->as.fn.doc;   // mirror so Decl.doc is uniform across kinds
            return d;
        }
        case TOK_STRUCT:    return parse_struct(p);
        case TOK_TYPE: {
            // `type UserId = int` — a distinct nominal type over a base (OFI-149).
            Decl *d = arena_alloc(p->arena, sizeof(Decl));
            d->kind = DECL_TYPE;
            d->line = cur(p)->line;
            d->col  = cur(p)->col;
            d->doc  = tok_doc(p, cur(p));
            adv(p);   // consume `type`
            const Token *name = expect(p, TOK_IDENT, "expected a type name after 'type'");
            d->as.type_.name = tok_text(p, name);
            expect(p, TOK_ASSIGN, "expected '=' in a type declaration");
            d->as.type_.base = parse_type(p);
            // OFI-150: an optional `where <predicate>` makes this a REFINEMENT type — the predicate
            // (over `self`) is checked at construction.
            d->as.type_.refinement = match(p, TOK_WHERE) ? parse_expression(p) : NULL;
            return d;
        }
        case TOK_ENUM:      return parse_enum(p);
        case TOK_INTERFACE: return parse_interface(p);
        case TOK_IMPORT:    return parse_import(p);
        case TOK_EXTERN:    return parse_extern(p);
        case TOK_LET:       return parse_global_let(p, 0);
        case TOK_VAR:       return parse_global_let(p, 1);
        default:
            error_at(p, cur(p), "expected a declaration "
                                "(fn, struct, enum, interface, import, extern, let/var)");
            return NULL;
    }
}





Program parser_parse(const Token *tokens, size_t count, Arena *arena,
                     const char *source_name, int *had_error) {
    Parser p;
    p.toks      = tokens;
    p.count     = count;
    p.pos       = 0;
    p.arena     = arena;
    p.src_name  = source_name;
    p.had_error = 0;
    p.panic     = 0;
    p.no_struct = 0;
    p.depth     = 0;

    Vec decls;
    vec_init(&decls, sizeof(Decl *));
    skip_newlines(&p);
    while (!at_end(&p)) {
        size_t before = p.pos;
        Decl *d = parse_decl(&p);
        if (d != NULL) {
            vec_push(&decls, &d);
        }
        if (p.panic) {
            synchronize(&p);
        }
        if (p.pos == before) {
            adv(&p); // guarantee progress
        }
        skip_newlines(&p);
    }

    Program prog;
    prog.decls = vec_to_arena(arena, &decls, &prog.count);
    *had_error = p.had_error;
    return prog;
}
