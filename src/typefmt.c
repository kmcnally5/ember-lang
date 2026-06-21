#include "typefmt.h"

// The shared surface-syntax formatter (see typefmt.h). Every branch writes through the sink, so
// one implementation serves the LSP (hover/completion, into a JsonBuf) and the docs generator
// (into a FILE*). Keep this the single place type/signature syntax is rendered for humans.




// emit appends one string to the sink.
static void emit(const TypeSink *sink, const char *s) {
    sink->put(sink->ctx, s);
}




void typefmt_type(const TypeSink *sink, const Type *t) {
    if (t == NULL) {
        emit(sink, "()");
        return;
    }
    switch (t->kind) {
        case TYPE_NAME:
            if (t->as.name.qualifier != NULL) {
                emit(sink, t->as.name.qualifier);
                emit(sink, ".");
            }
            emit(sink, t->as.name.name);
            break;
        case TYPE_GENERIC:
            emit(sink, t->as.generic.name);
            emit(sink, "<");
            for (size_t i = 0; i < t->as.generic.arg_count; i++) {
                if (i > 0) { emit(sink, ", "); }
                typefmt_type(sink, t->as.generic.args[i]);
            }
            emit(sink, ">");
            break;
        case TYPE_ARRAY:
            emit(sink, "[");
            typefmt_type(sink, t->as.array.elem);
            emit(sink, "]");
            break;
        case TYPE_FN:
            emit(sink, "fn(");
            for (size_t i = 0; i < t->as.fn.param_count; i++) {
                if (i > 0) { emit(sink, ", "); }
                typefmt_type(sink, t->as.fn.params[i]);
            }
            emit(sink, ")");
            if (t->as.fn.ret != NULL) {
                emit(sink, " -> ");
                typefmt_type(sink, t->as.fn.ret);
            }
            break;
        default:
            emit(sink, "?");
    }
}




void typefmt_fn(const TypeSink *sink, const FnDecl *fn) {
    emit(sink, "fn ");
    emit(sink, fn->name);
    emit(sink, "(");
    for (size_t i = 0; i < fn->param_count; i++) {
        if (i > 0) { emit(sink, ", "); }
        if (fn->params[i].is_self) {
            emit(sink, "self");
            continue;
        }
        if (fn->params[i].qual == OWN_MUT)  { emit(sink, "mut "); }
        if (fn->params[i].qual == OWN_MOVE) { emit(sink, "move "); }
        emit(sink, fn->params[i].name);
        emit(sink, ": ");
        typefmt_type(sink, fn->params[i].type);
    }
    emit(sink, ")");
    if (fn->return_type != NULL) {
        emit(sink, " -> ");
        typefmt_type(sink, fn->return_type);
    }
}
