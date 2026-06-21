#include "trace.h"

#include <stdio.h>

// json_lines_on_event writes one event as a single JSON object, e.g.
//   {"ip":4,"op":"ADD","line":3,"stack":[1,2]}
// One object per line (JSON Lines) so a consumer can stream the tape.
static void json_lines_on_event(void *ctx, const TraceEvent *event) {
    FILE *out = (FILE *)ctx;
    // A semantic event (e.g. a contract violation) is a distinct, richer record so a
    // tool can spot it without scanning every step. Ordinary steps keep their shape,
    // so existing tapes are unchanged.
    if (event->event != NULL) {
        fprintf(out,
                "{\"event\":\"%s\",\"fn\":\"%s\",\"line\":%d,\"detail\":\"%s\",\"stack\":[",
                event->event, event->fn, event->line,
                event->detail != NULL ? event->detail : "");
        for (size_t i = 0; i < event->stack_count; i++) {
            if (i > 0) {
                fputc(',', out);
            }
            Value v = event->stack[i];
            if (IS_INT(v)) {
                fprintf(out, "%lld", (long long)AS_INT(v));
            } else if (IS_FLOAT(v)) {
                fprintf(out, "%g", AS_FLOAT(v));
            } else if (IS_STRING(v)) {
                fprintf(out, "\"%s\"", AS_CSTRING(v));
            } else {
                fputs("\"<obj>\"", out);
            }
        }
        fputs("]}\n", out);
        return;
    }
    fprintf(out, "{\"fn\":\"%s\",\"ip\":%zu,\"op\":\"%s\",\"line\":%d,\"stack\":[",
            event->fn, event->ip, opcode_name(event->op), event->line);
    for (size_t i = 0; i < event->stack_count; i++) {
        if (i > 0) {
            fputc(',', out);
        }
        Value v = event->stack[i];
        if (IS_INT(v)) {
            fprintf(out, "%lld", (long long)AS_INT(v));
        } else if (IS_FLOAT(v)) {
            fprintf(out, "%g", AS_FLOAT(v));
        } else if (IS_STRING(v)) {
            fprintf(out, "\"%s\"", AS_CSTRING(v));
        } else {
            // A heap value (struct/enum instance): show its kind, not its address.
            fputs("\"<obj>\"", out);
        }
    }
    fputs("]}\n", out);
}





Tracer tracer_json_lines(void *out) {
    Tracer tracer;
    tracer.on_event = json_lines_on_event;
    tracer.ctx      = out;
    return tracer;
}
