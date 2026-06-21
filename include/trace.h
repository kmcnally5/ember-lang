#ifndef EMBER_TRACE_H
#define EMBER_TRACE_H

#include "chunk.h"
#include "opcode.h"
#include <stddef.h>

// Ember's execution-observability seam (the basis for the FROG-style `--tape`).
//
// The VM fires one TraceEvent immediately *before* it executes each instruction.
// A trace sink subscribes to those events; the VM holds at most one (passed to
// vm_run, or NULL to disable at ~zero cost — a single nil check per instruction).
// Sinks are observer-only: they may read the event and do anything external
// (log it, write a tape, ask an LLM) but cannot alter execution. Richer semantic
// events (errors, task lifecycle) and user-registerable hooks layer on top later
// as those language features land.

typedef struct {
    const char  *fn;          // name of the function currently executing
    size_t       ip;          // byte offset of the instruction in that function's chunk
    OpCode       op;          // the instruction about to execute
    int          line;        // source line it was lowered from (0 if unknown)
    const Value *stack;       // base of the value stack
    size_t       stack_count; // number of values currently on the stack
    // Semantic events (MANIFESTO §5c). NULL for an ordinary per-instruction step;
    // when set, this is a richer event whose machine-readable name is `event` (e.g.
    // "contract_violation") and whose description is `detail`. This is the closed
    // loop for an LLM author: a contract it wrote, failing, reported as structured
    // data it can act on — not just an abort.
    const char  *event;       // semantic-event name, or NULL for a plain step
    const char  *detail;      // the event's description (e.g. the contract message)
} TraceEvent;

// A trace sink: an event callback plus opaque context.
typedef struct {
    void (*on_event)(void *ctx, const TraceEvent *event);
    void  *ctx;
} Tracer;

// Built-in tape sink: writes one JSON object per event (JSON Lines) to `out`,
// which must be a FILE*. The caller owns `out`. This is the default `--tape`
// recorder; the format is deliberately simple so an LLM (or any tool) can parse
// it line by line.
Tracer tracer_json_lines(void *out);

#endif // EMBER_TRACE_H
