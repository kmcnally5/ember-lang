#include "fault.h"
#include "jsonw.h"

// The active render mode. Defaults to HUMAN so an ordinary `emberc --emit=run` at a terminal
// keeps a readable, teacher-voice failure; `--faults=agent` flips it to JSON Lines for an LLM.
static FaultRenderMode g_fault_mode = FAULT_RENDER_HUMAN;




void fault_set_mode(FaultRenderMode mode) {
    g_fault_mode = mode;
}




FaultRenderMode fault_get_mode(void) {
    return g_fault_mode;
}




const char *fault_severity_name(FaultSeverity s) {
    switch (s) {
        case FSEV_ERROR:   return "error";
        case FSEV_WARNING: return "warning";
        case FSEV_NOTE:    return "note";
    }
    return "error";
}




const char *fault_category_name(FaultCategory c) {
    switch (c) {
        case FCAT_PARSE:          return "parse";
        case FCAT_TYPE:           return "type";
        case FCAT_CONTRACT:       return "contract";
        case FCAT_RUNTIME:        return "runtime";
        case FCAT_UNHANDLED_ERR:  return "unhandled_err";
        case FCAT_COUNTEREXAMPLE: return "counterexample";
    }
    return "runtime";
}




// The HUMAN render: the familiar `error[code]: message` header, the location, then the
// violated intent, the concrete values, the route, and a hint — each on its own labelled
// line. No source excerpt/caret yet: the runtime retains no source text and Chunk.lines is
// line-only (a Phase 2 follow-up; see docs/faults.md). Carets/colour stay on this path only.
static void render_human(const Fault *f, FILE *out) {
    fprintf(out, "%s[%s]: %s\n",
            fault_severity_name(f->severity),
            f->code != NULL ? f->code : "",
            f->message != NULL ? f->message : "");

    fputs("  --> ", out);
    if (f->file != NULL) {
        fputs(f->file, out);
        if (f->line > 0) {
            fprintf(out, ":%d", f->line);
            if (f->col > 0) {
                fprintf(out, ":%d", f->col);
            }
        }
    } else if (f->line > 0) {
        fprintf(out, "line %d", f->line);
    } else {
        fputs("(unknown location)", out);
    }
    if (f->fn != NULL) {
        fprintf(out, " (in %s)", f->fn);
    }
    fputc('\n', out);

    if (f->why != NULL) {
        fprintf(out, "  why:    %s\n", f->why);
    }
    if (f->value_count > 0) {
        fputs("  values: ", out);
        for (int i = 0; i < f->value_count; i++) {
            if (i > 0) {
                fputs(", ", out);
            }
            fprintf(out, "%s = %s", f->values[i].name, f->values[i].rendered);
        }
        fputc('\n', out);
    }
    // Show the route only when there is a real call chain (more than the surfacing frame).
    if (f->route_count > 1) {
        fputs("  route:  ", out);
        for (int i = 0; i < f->route_count; i++) {
            if (i > 0) {
                fputs(" <- ", out);
            }
            fprintf(out, "%s (line %d)", f->route[i].fn, f->route[i].line);
        }
        fputc('\n', out);
    }
    if (f->hint != NULL) {
        fprintf(out, "  hint:   %s\n", f->hint);
    }
}




// The AGENT render: one escaped JSON object on a single line (JSON Lines), marker-free and
// ANSI-free (every string flows through json_write_string). Empty fields are OMITTED, not
// emitted as null, so the record stays minimal-sufficient — noise hurts an LLM (docs/faults.md).
static void render_agent(const Fault *f, FILE *out) {
    fputs("{\"severity\":", out);
    json_write_string(out, fault_severity_name(f->severity));
    fputs(",\"category\":", out);
    json_write_string(out, fault_category_name(f->category));
    fputs(",\"code\":", out);
    json_write_string(out, f->code);
    fputs(",\"message\":", out);
    json_write_string(out, f->message);
    if (f->file != NULL) {
        fputs(",\"file\":", out);
        json_write_string(out, f->file);
    }
    if (f->line > 0) {
        fprintf(out, ",\"line\":%d", f->line);
        if (f->col > 0) {
            fprintf(out, ",\"col\":%d", f->col);
        }
    }
    if (f->fn != NULL) {
        fputs(",\"fn\":", out);
        json_write_string(out, f->fn);
    }
    if (f->why != NULL) {
        fputs(",\"why\":", out);
        json_write_string(out, f->why);
    }
    if (f->value_count > 0) {
        fputs(",\"values\":[", out);
        for (int i = 0; i < f->value_count; i++) {
            if (i > 0) {
                fputc(',', out);
            }
            fputs("{\"name\":", out);
            json_write_string(out, f->values[i].name);
            fputs(",\"value\":", out);
            json_write_string(out, f->values[i].rendered);
            fputc('}', out);
        }
        fputc(']', out);
    }
    if (f->route_count > 0) {
        fputs(",\"route\":[", out);
        for (int i = 0; i < f->route_count; i++) {
            if (i > 0) {
                fputc(',', out);
            }
            fputs("{\"fn\":", out);
            json_write_string(out, f->route[i].fn);
            fprintf(out, ",\"line\":%d}", f->route[i].line);
        }
        fputc(']', out);
    }
    if (f->hint != NULL) {
        fputs(",\"hint\":", out);
        json_write_string(out, f->hint);
    }
    fputs("}\n", out);
}




void fault_render(const Fault *f, FILE *out) {
    if (g_fault_mode == FAULT_RENDER_AGENT) {
        render_agent(f, out);
    } else {
        render_human(f, out);
    }
}
