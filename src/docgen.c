#include "docgen.h"
#include "ast.h"
#include "typefmt.h"

#include <stdio.h>

// The Markdown documentation generator (see docgen.h). It walks the parsed
// Program and prints a reference page to `out`. Type and signature rendering goes
// through the shared surface-syntax formatter (src/typefmt.c) — the very code the
// LSP's hover uses — so the docs and the editor tooltip can't drift (OFI-034).
// Nothing here allocates: it streams straight to the FILE*.




// file_sink_put adapts a FILE* to the shared formatter's TypeSink (typefmt.h).
static void file_sink_put(void *ctx, const char *s) {
    fputs(s, (FILE *)ctx);
}

// fmt_type / fmt_fn_sig print a type / signature to `out` via the one shared surface-syntax
// formatter (src/typefmt.c) — the same code the LSP's hover uses, so the docs and the editor
// tooltip render identically (OFI-034).
static void fmt_type(FILE *out, const Type *t) {
    TypeSink sink = { file_sink_put, out };
    typefmt_type(&sink, t);
}

static void fmt_fn_sig(FILE *out, const FnDecl *fn) {
    TypeSink sink = { file_sink_put, out };
    typefmt_fn(&sink, fn);
}




// emit_doc prints a cleaned `///` doc comment as its own paragraph, or nothing
// when the declaration carries no doc.
static void emit_doc(FILE *out, const char *doc) {
    if (doc != NULL && doc[0] != '\0') {
        fputs(doc, out);
        fputs("\n\n", out);
    }
}




// emit_struct prints a struct's fields and methods as sub-sections.
static void emit_struct(FILE *out, const Decl *d) {
    if (d->as.struct_.field_count > 0) {
        fputs("**Fields**\n\n", out);
        for (size_t i = 0; i < d->as.struct_.field_count; i++) {
            const Field *f = &d->as.struct_.fields[i];
            fputs("- `", out);
            fputs(f->name, out);
            fputs(": ", out);
            fmt_type(out, f->type);
            fputc('`', out);
            if (f->doc != NULL && f->doc[0] != '\0') {
                fputs(" — ", out);
                fputs(f->doc, out);
            }
            fputc('\n', out);
        }
        fputc('\n', out);
    }
    for (size_t i = 0; i < d->as.struct_.method_count; i++) {
        const FnDecl *m = &d->as.struct_.methods[i];
        fputs("#### `", out);
        fmt_fn_sig(out, m);
        fputs("`\n\n", out);
        emit_doc(out, m->doc);
    }
}




// emit_enum prints an enum's variants (with any payload fields) as a list.
static void emit_enum(FILE *out, const Decl *d) {
    if (d->as.enum_.variant_count == 0) {
        return;
    }
    fputs("**Variants**\n\n", out);
    for (size_t i = 0; i < d->as.enum_.variant_count; i++) {
        const Variant *v = &d->as.enum_.variants[i];
        fputs("- `", out);
        fputs(v->name, out);
        if (v->field_count > 0) {
            fputc('(', out);
            for (size_t f = 0; f < v->field_count; f++) {
                if (f > 0) { fputs(", ", out); }
                fputs(v->fields[f].name, out);
                fputs(": ", out);
                fmt_type(out, v->fields[f].type);
            }
            fputc(')', out);
        }
        fputc('`', out);
        if (v->doc != NULL && v->doc[0] != '\0') {
            fputs(" — ", out);
            fputs(v->doc, out);
        }
        fputc('\n', out);
    }
    fputc('\n', out);
}




// emit_interface prints an interface's required method signatures.
static void emit_interface(FILE *out, const Decl *d) {
    for (size_t i = 0; i < d->as.interface.method_count; i++) {
        const FnDecl *m = &d->as.interface.methods[i];
        fputs("#### `", out);
        fmt_fn_sig(out, m);
        fputs("`\n\n", out);
        emit_doc(out, m->doc);
    }
}




// emit_section prints the `## name` heading and fenced signature for one
// top-level declaration, returning 0 for kinds that get no page (imports).
static int emit_section(FILE *out, const Decl *d) {
    switch (d->kind) {
        case DECL_FN:
            fprintf(out, "## %s\n\n```ember\n", d->as.fn.name);
            fmt_fn_sig(out, &d->as.fn);
            fputs("\n```\n\n", out);
            emit_doc(out, d->doc);
            return 1;
        case DECL_STRUCT:
            fprintf(out, "## %s\n\n```ember\nstruct %s\n```\n\n",
                    d->as.struct_.name, d->as.struct_.name);
            emit_doc(out, d->doc);
            emit_struct(out, d);
            return 1;
        case DECL_ENUM:
            fprintf(out, "## %s\n\n```ember\nenum %s\n```\n\n",
                    d->as.enum_.name, d->as.enum_.name);
            emit_doc(out, d->doc);
            emit_enum(out, d);
            return 1;
        case DECL_INTERFACE:
            fprintf(out, "## %s\n\n```ember\ninterface %s\n```\n\n",
                    d->as.interface.name, d->as.interface.name);
            emit_doc(out, d->doc);
            emit_interface(out, d);
            return 1;
        case DECL_LET:
            fprintf(out, "## %s\n\n```ember\nlet %s",
                    d->as.let.name, d->as.let.name);
            if (d->as.let.type != NULL) {
                fputs(": ", out);
                fmt_type(out, d->as.let.type);
            }
            fputs("\n```\n\n", out);
            emit_doc(out, d->doc);
            return 1;
        default:
            return 0;   // imports/extern blocks get no reference page
    }
}




void docgen_emit(const Program *prog, const char *title, FILE *out) {
    fprintf(out, "# %s\n\n", title != NULL ? title : "Module");
    fputs("_Generated by `emberc --emit=docs` from `///` doc comments._\n\n", out);
    for (size_t i = 0; i < prog->count; i++) {
        emit_section(out, prog->decls[i]);
    }
}
