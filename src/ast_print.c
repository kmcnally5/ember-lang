#include "ast.h"

#include <stdio.h>

// A stable, indented textual dump of the AST. The format is for human reading
// and golden tests, not for re-parsing, so it favours clarity. Source positions
// are omitted on purpose, so the goldens survive whitespace edits to a test.

static void print_expr(const Expr *e, int depth);
static void print_stmt(const Stmt *s, int depth);
static void print_block(const Block *b, int depth);
static void print_fn(const FnDecl *fn, int depth);
static void print_decl(const Decl *d, int depth);

// ind emits `depth` levels of two-space indentation.
static void ind(int depth) {
    for (int i = 0; i < depth; i++) {
        printf("  ");
    }
}





// print_type writes a type inline (no newline): `[string]`, `Result<A, B>`.
static void print_type(const Type *t) {
    if (t == NULL) {
        printf("<none>");
        return;
    }
    switch (t->kind) {
        case TYPE_NAME:
            printf("%s", t->as.name.name);
            break;
        case TYPE_ARRAY:
            printf("[");
            print_type(t->as.array.elem);
            printf("]");
            break;
        case TYPE_GENERIC:
            printf("%s<", t->as.generic.name);
            for (size_t i = 0; i < t->as.generic.arg_count; i++) {
                if (i > 0) {
                    printf(", ");
                }
                print_type(t->as.generic.args[i]);
            }
            printf(">");
            break;
        case TYPE_FN:
            printf("fn(");
            for (size_t i = 0; i < t->as.fn.param_count; i++) {
                if (i > 0) {
                    printf(", ");
                }
                print_type(t->as.fn.params[i]);
            }
            printf(")");
            if (t->as.fn.ret != NULL) {
                printf(" -> ");
                print_type(t->as.fn.ret);
            }
            break;
    }
}





// print_generics emits the `<T, U: Bound>` parameter list on its own line.
static void print_generics(const GenericParam *gen, size_t count, int depth) {
    if (count == 0) {
        return;
    }
    ind(depth);
    printf("generics:");
    for (size_t i = 0; i < count; i++) {
        printf(" %s", gen[i].name);
        for (int b = 0; b < gen[i].bound_count; b++) {
            printf("%s%s", b == 0 ? ": " : " + ", gen[i].bounds[b]);
        }
    }
    printf("\n");
}





// print_implements emits the nominal-conformance list on its own line.
static void print_implements(const char *const *names, size_t count, int depth) {
    if (count == 0) {
        return;
    }
    ind(depth);
    printf("implements:");
    for (size_t i = 0; i < count; i++) {
        printf(" %s", names[i]);
    }
    printf("\n");
}





static void print_expr(const Expr *e, int depth) {
    if (e == NULL) {
        ind(depth);
        printf("<error-expr>\n");
        return;
    }
    switch (e->kind) {
        case EXPR_INT:
            ind(depth);
            printf("Int %lld\n", e->as.int_lit);
            break;
        case EXPR_FLOAT:
            ind(depth);
            printf("Float %g\n", e->as.float_lit);
            break;
        case EXPR_STRING:
            ind(depth);
            if (e->as.str.part_count == 1 && e->as.str.parts[0].expr == NULL) {
                printf("String \"%s\"\n", e->as.str.parts[0].text);
            } else {
                printf("String (interpolated, %zu parts)\n", e->as.str.part_count);
                for (size_t i = 0; i < e->as.str.part_count; i++) {
                    const StrPart *part = &e->as.str.parts[i];
                    if (part->expr != NULL) {
                        ind(depth + 1);
                        printf("hole:\n");
                        print_expr(part->expr, depth + 2);
                    } else {
                        ind(depth + 1);
                        printf("text \"%s\"\n", part->text);
                    }
                }
            }
            break;
        case EXPR_BOOL:
            ind(depth);
            printf("Bool %s\n", e->as.bool_lit ? "true" : "false");
            break;
        case EXPR_IDENT:
            ind(depth);
            printf("Ident %s\n", e->as.ident);
            break;
        case EXPR_FN_VALUE:   // only present post-check; the AST dump runs pre-check
            ind(depth);
            printf("FnValue #%d\n", e->as.fn_value);
            break;
        case EXPR_RANGE:
            ind(depth);
            printf("Range\n");
            print_expr(e->as.range.lo, depth + 1);
            print_expr(e->as.range.hi, depth + 1);
            break;
        case EXPR_LAMBDA:
            ind(depth);
            printf("Lambda(");
            for (size_t i = 0; i < e->as.lambda.param_count; i++) {
                if (i > 0) {
                    printf(", ");
                }
                printf("%s", e->as.lambda.params[i].name);
            }
            printf(")\n");
            break;
        case EXPR_UNARY:
            ind(depth);
            printf("Unary %s\n", token_type_name(e->as.unary.op));
            print_expr(e->as.unary.operand, depth + 1);
            break;
        case EXPR_BINARY:
            ind(depth);
            printf("Binary %s\n", token_type_name(e->as.binary.op));
            print_expr(e->as.binary.left, depth + 1);
            print_expr(e->as.binary.right, depth + 1);
            break;
        case EXPR_CALL:
            ind(depth);
            printf("Call\n");
            ind(depth + 1);
            printf("callee:\n");
            print_expr(e->as.call.callee, depth + 2);
            if (e->as.call.arg_count > 0) {
                ind(depth + 1);
                printf("args:\n");
                for (size_t i = 0; i < e->as.call.arg_count; i++) {
                    print_expr(e->as.call.args[i], depth + 2);
                }
            }
            break;
        case EXPR_GET:
            ind(depth);
            printf("Get .%s\n", e->as.get.name);
            print_expr(e->as.get.object, depth + 1);
            break;
        case EXPR_INDEX:
            ind(depth);
            printf("Index\n");
            print_expr(e->as.index.object, depth + 1);
            print_expr(e->as.index.index, depth + 1);
            break;
        case EXPR_ARRAY:
            ind(depth);
            printf("Array (%zu)\n", e->as.array.count);
            for (size_t i = 0; i < e->as.array.count; i++) {
                print_expr(e->as.array.elems[i], depth + 1);
            }
            break;
        case EXPR_STRUCT_LIT:
            ind(depth);
            printf("StructLit ");
            print_type(e->as.struct_lit.type);
            printf("\n");
            for (size_t i = 0; i < e->as.struct_lit.field_count; i++) {
                ind(depth + 1);
                printf("%s:\n", e->as.struct_lit.fields[i].name);
                print_expr(e->as.struct_lit.fields[i].value, depth + 2);
            }
            break;
        case EXPR_TRY:
            ind(depth);
            printf("Try\n");
            print_expr(e->as.try_.operand, depth + 1);
            break;
    }
}





static void print_pattern(const Pattern *pat) {
    if (pat->type_name != NULL) {
        printf("%s.", pat->type_name);
    }
    printf("%s", pat->variant);
    if (pat->binding_count > 0) {
        printf("(");
        for (size_t i = 0; i < pat->binding_count; i++) {
            if (i > 0) {
                printf(", ");
            }
            printf("%s", pat->bindings[i]);
        }
        printf(")");
    }
}





static void print_stmt(const Stmt *s, int depth) {
    switch (s->kind) {
        case STMT_LET:
            ind(depth);
            printf("%s %s", s->as.let.is_var ? "Var" : "Let", s->as.let.name);
            if (s->as.let.type != NULL) {
                printf(": ");
                print_type(s->as.let.type);
            }
            printf("\n");
            print_expr(s->as.let.value, depth + 1);
            break;
        case STMT_RETURN:
            ind(depth);
            printf("Return\n");
            if (s->as.ret.value != NULL) {
                print_expr(s->as.ret.value, depth + 1);
            } else {
                ind(depth + 1);
                printf("(unit)\n");
            }
            break;
        case STMT_EXPR:
            ind(depth);
            printf("ExprStmt\n");
            print_expr(s->as.expr.expr, depth + 1);
            break;
        case STMT_ASSIGN:
            ind(depth);
            printf("Assign\n");
            ind(depth + 1);
            printf("target:\n");
            print_expr(s->as.assign.target, depth + 2);
            ind(depth + 1);
            printf("value:\n");
            print_expr(s->as.assign.value, depth + 2);
            break;
        case STMT_IF:
            ind(depth);
            printf("If\n");
            ind(depth + 1);
            printf("cond:\n");
            print_expr(s->as.if_.cond, depth + 2);
            ind(depth + 1);
            printf("then:\n");
            print_block(&s->as.if_.then_blk, depth + 2);
            if (s->as.if_.else_branch != NULL) {
                ind(depth + 1);
                printf("else:\n");
                print_stmt(s->as.if_.else_branch, depth + 2);
            }
            break;
        case STMT_FOR:
            ind(depth);
            printf("For %s\n", s->as.for_.var);
            ind(depth + 1);
            printf("iter:\n");
            print_expr(s->as.for_.iter, depth + 2);
            ind(depth + 1);
            printf("body:\n");
            print_block(&s->as.for_.body, depth + 2);
            break;
        case STMT_LOOP:
            ind(depth);
            printf("Loop\n");
            print_block(&s->as.loop.body, depth + 1);
            break;
        case STMT_BREAK:
            ind(depth);
            printf("Break\n");
            break;
        case STMT_CONTINUE:
            ind(depth);
            printf("Continue\n");
            break;
        case STMT_MATCH:
            ind(depth);
            printf("Match\n");
            ind(depth + 1);
            printf("value:\n");
            print_expr(s->as.match.value, depth + 2);
            for (size_t i = 0; i < s->as.match.case_count; i++) {
                ind(depth + 1);
                printf("case ");
                print_pattern(&s->as.match.cases[i].pattern);
                printf("\n");
                print_block(&s->as.match.cases[i].body, depth + 2);
            }
            break;
        case STMT_SPAWN:
            ind(depth);
            printf("Spawn\n");
            print_expr(s->as.spawn.call, depth + 1);
            break;
        case STMT_NURSERY:
            ind(depth);
            printf("Nursery\n");
            print_block(&s->as.nursery.body, depth + 1);
            break;
        case STMT_BLOCK:
            ind(depth);
            printf("Block\n");
            print_block(&s->as.block.body, depth + 1);
            break;
    }
}





static void print_block(const Block *b, int depth) {
    for (size_t i = 0; i < b->count; i++) {
        print_stmt(b->stmts[i], depth);
    }
}





static void print_fn(const FnDecl *fn, int depth) {
    ind(depth);
    printf("Fn %s\n", fn->name);
    print_generics(fn->generics, fn->generic_count, depth + 1);

    ind(depth + 1);
    printf("params:\n");
    for (size_t i = 0; i < fn->param_count; i++) {
        const Param *param = &fn->params[i];
        ind(depth + 2);
        if (param->qual == OWN_MUT) {
            printf("mut ");
        } else if (param->qual == OWN_MOVE) {
            printf("move ");
        }
        if (param->is_self) {
            printf("self\n");
        } else {
            printf("%s: ", param->name);
            print_type(param->type);
            printf("\n");
        }
    }

    if (fn->return_type != NULL) {
        ind(depth + 1);
        printf("returns: ");
        print_type(fn->return_type);
        printf("\n");
    }

    if (fn->has_body) {
        ind(depth + 1);
        printf("body:\n");
        print_block(&fn->body, depth + 2);
    } else {
        ind(depth + 1);
        printf("(signature)\n");
    }
}





static void print_decl(const Decl *d, int depth) {
    switch (d->kind) {
        case DECL_FN:
            print_fn(&d->as.fn, depth);
            break;
        case DECL_STRUCT:
            ind(depth);
            printf("Struct %s\n", d->as.struct_.name);
            print_generics(d->as.struct_.generics,
                           d->as.struct_.generic_count, depth + 1);
            print_implements(d->as.struct_.implements,
                             d->as.struct_.implements_count, depth + 1);
            for (size_t i = 0; i < d->as.struct_.field_count; i++) {
                ind(depth + 1);
                printf("field %s: ", d->as.struct_.fields[i].name);
                print_type(d->as.struct_.fields[i].type);
                printf("\n");
            }
            for (size_t i = 0; i < d->as.struct_.method_count; i++) {
                print_fn(&d->as.struct_.methods[i], depth + 1);
            }
            break;
        case DECL_ENUM:
            ind(depth);
            printf("Enum %s\n", d->as.enum_.name);
            print_generics(d->as.enum_.generics,
                           d->as.enum_.generic_count, depth + 1);
            print_implements(d->as.enum_.implements,
                             d->as.enum_.implements_count, depth + 1);
            for (size_t i = 0; i < d->as.enum_.variant_count; i++) {
                const Variant *v = &d->as.enum_.variants[i];
                ind(depth + 1);
                printf("variant %s", v->name);
                if (v->field_count > 0) {
                    printf("(");
                    for (size_t j = 0; j < v->field_count; j++) {
                        if (j > 0) {
                            printf(", ");
                        }
                        printf("%s: ", v->fields[j].name);
                        print_type(v->fields[j].type);
                    }
                    printf(")");
                }
                printf("\n");
            }
            break;
        case DECL_INTERFACE:
            ind(depth);
            printf("Interface %s\n", d->as.interface.name);
            print_generics(d->as.interface.generics,
                           d->as.interface.generic_count, depth + 1);
            for (size_t i = 0; i < d->as.interface.method_count; i++) {
                print_fn(&d->as.interface.methods[i], depth + 1);
            }
            break;
        case DECL_IMPORT:
            ind(depth);
            printf("Import \"%s\" as %s\n",
                   d->as.import.path, d->as.import.alias);
            break;
        case DECL_LET:
            ind(depth);
            printf("%s %s", d->as.let.is_var ? "Var" : "Let", d->as.let.name);
            if (d->as.let.type != NULL) {
                printf(": ");
                print_type(d->as.let.type);
            }
            printf("\n");
            print_expr(d->as.let.value, depth + 1);
            break;
        case DECL_EXTERN:
            ind(depth);
            printf("Extern \"%s\"\n", d->as.extern_.abi);
            for (size_t i = 0; i < d->as.extern_.fn_count; i++) {
                print_fn(&d->as.extern_.fns[i], depth + 1);
            }
            break;
        case DECL_TYPE:
            ind(depth);
            printf("Type %s = ", d->as.type_.name);
            print_type(d->as.type_.base);
            printf("\n");
            break;
    }
}





void ast_print(const Program *program) {
    printf("Program\n");
    for (size_t i = 0; i < program->count; i++) {
        print_decl(program->decls[i], 1);
    }
}
