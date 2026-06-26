#ifndef EMBER_FAULT_H
#define EMBER_FAULT_H

#include <stdio.h>

// A Fault is Ember's ONE structured failure artifact (the campaign in docs/faults.md):
// every failure class — a runtime abort, a contract violation, a compile error, an Err
// reaching main — is meant to converge onto this single record, rendered TWO ways from one
// source of truth: a HUMAN render (teacher-voice, the familiar stderr stream) and an AGENT
// render (terse, marker-free JSON Lines an LLM consumes to auto-repair the code).
//
// Phase 1 populates Faults for the BUILTIN runtime traps (index out of bounds, divide by
// zero, overflow, shift, slice, …): each is reported as a violated IMPLICIT contract
// ("indexing requires 0 <= index < len"), carrying the concrete operand VALUES projected
// from the live VM — never hallucinated. why (the violated intent) and values (the effect)
// are the two strongest signals for LLM program-repair (see docs/faults.md).

typedef enum { FSEV_ERROR, FSEV_WARNING, FSEV_NOTE } FaultSeverity;

// Coarse failure class. Phase 1 emits FCAT_RUNTIME; the rest are the convergence targets
// the later phases route onto this same record (kept here so the schema is the full union).
typedef enum {
    FCAT_PARSE,           // lexer/parser error
    FCAT_TYPE,            // type / borrow / linearity error
    FCAT_CONTRACT,        // requires/ensures/assert violation
    FCAT_RUNTIME,         // a builtin trap: index, divide-by-zero, overflow, shift, slice, …
    FCAT_UNHANDLED_ERR,   // an Err/None reached main
    FCAT_COUNTEREXAMPLE   // --check falsified an ensures
} FaultCategory;

// One concrete value involved in the failure (e.g. index = 7, len = 5). `rendered` is the
// value already stringified — an inline buffer so a Fault can be built on the abort path
// with no heap allocation. The recursive struct/enum/array value walker (OFI-111b,
// render_value_into in src/vm.c) renders a non-scalar payload as data (e.g. Err("io"),
// MyErr { code: 5 }) rather than <obj>.
typedef struct {
    const char *name;        // role label ("index", "len", "divisor"); borrowed/static
    char        rendered[256]; // the value, stringified by the recursive walker (OFI-111b);
                               // truncates gracefully if a payload is very large or deeply nested
} FaultValue;

// One frame in the route — the call chain the failure surfaced through (origin last). For a
// builtin trap this is the synchronous backtrace at the abort instant (walking the VM frames).
typedef struct {
    const char *fn;          // function name; borrowed (lives as long as the program)
    int         line;        // 1-based source line within that frame
} FaultHop;

#define FAULT_MAX_VALUES 6
#define FAULT_MAX_HOPS  32

typedef struct {
    FaultSeverity severity;
    FaultCategory category;
    const char   *code;       // stable machine handle, e.g. "index_out_of_bounds"; borrowed/static
    const char   *message;    // one-line human summary; borrowed/static
    const char   *file;       // source path, or NULL if unknown at this site; borrowed
    const char   *fn;         // function the failure surfaced in, or NULL; borrowed
    int           line;       // 1-based; 0 = unknown
    int           col;        // 1-based column of the failing expression; 0 = unknown (OFI-111a)
    const char   *why;        // the violated intent ("indexing requires 0 <= index < len"), or NULL
    const char   *hint;       // a concrete suggested fix in user terms, or NULL
    FaultValue    values[FAULT_MAX_VALUES];
    int           value_count;
    FaultHop      route[FAULT_MAX_HOPS];
    int           route_count;
} Fault;

// The render mode selects which face a Fault shows. HUMAN is the default (the familiar
// stderr stream, now richer); AGENT emits one escaped JSON object per line for tooling/LLMs.
typedef enum { FAULT_RENDER_HUMAN, FAULT_RENDER_AGENT } FaultRenderMode;

void            fault_set_mode(FaultRenderMode mode);   // set by the `--faults=` flag
FaultRenderMode fault_get_mode(void);

// Render `f` to `out` (stderr in practice) in the current mode. Pure over the Fault; both
// renderers reuse json_write_string for escaping so no control/ANSI byte leaks to the agent.
void fault_render(const Fault *f, FILE *out);

const char *fault_category_name(FaultCategory c);
const char *fault_severity_name(FaultSeverity s);

#endif // EMBER_FAULT_H
