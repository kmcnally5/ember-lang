#ifndef EMBER_VM_H
#define EMBER_VM_H

#include "program.h"
#include "trace.h"
#include "fault.h"

typedef enum {
    VM_OK,
    VM_RUNTIME_ERROR,
    VM_YIELD,           // a fiber blocked on a channel — internal to the scheduler
    VM_CANCELLED        // (M:N) a fiber unwound because its nursery was cancelled — quiet, like YIELD
} VMResult;

// The VM owns the heap objects a run allocates. Its lifetime is managed by the
// caller so that a returned heap value (a string/struct/enum) stays valid until
// the caller is done with it — then vm_destroy frees everything.
typedef struct VM VM;

// Creates a VM ready to execute `prog` from its `main` function.
VM *vm_create(const CompiledProgram *prog);

// Sets the program's command-line arguments (everything after the source file), surfaced
// to Ember through the `args()` builtin. Called once by the `run` driver before execution.
void vm_set_program_args(int argc, char **argv);

// Sets the entry source path, used as the `file` of a runtime Fault. Called once by the
// `run`/`trace` driver before execution (NULL leaves Faults file-less but still line-precise).
void vm_set_source_path(const char *path);

// Copies the recorded `?`-propagation route (OFI-108) into `route` (capacity FAULT_MAX_HOPS),
// setting *count — the chain of `?` hops an Err travelled, for an unhandled-Err-at-main Fault.
void vm_route(const VM *vm, FaultHop *route, int *count);

// After vm_run returns VM_OK, reports whether the program called `exit(code)`. If so,
// returns 1 and writes the code to *code; the driver should terminate with that code
// instead of printing main's return value.
int vm_exited(const VM *vm, int *code);

// Runs the VM. On VM_OK, *out receives the value main returns (valid until
// vm_destroy). On VM_RUNTIME_ERROR (division by zero, overflow, stack/call-depth
// exhaustion) a message is printed to stderr and *out is left untouched. If
// `tracer` is non-NULL, one event fires before each instruction (the tape).
VMResult vm_run(VM *vm, Value *out, const Tracer *tracer);

// OFI-111b: render a runtime Value (incl. structs/enums/arrays) into `buf` for a Fault's
// `values[]`, using `prog` for struct field + enum variant names. Bounded depth/budget; a bare
// top-level string is unquoted, nested strings quoted. VM-only (a native binary aborts bare).
void render_value_into(char *buf, size_t cap, Value v, const CompiledProgram *prog);

// Frees the VM and every heap object it allocated.
void vm_destroy(VM *vm);

// Verification loop (§5j): property-based contract checking. For every fuzzable function
// (a free, non-generic function with a falsifiable `ensures` and all-scalar params), generate
// random inputs that satisfy its `requires`, run it, and report the first input that violates a
// postcondition / `assert` (or crashes) as a structured counterexample. Returns the number of
// functions for which a counterexample was found (0 = all checks passed).
int vm_check(VM *vm, const Tracer *tracer);

// Verification loop (§5j): deterministic record-replay. Runs `prog` twice — once recording every
// nondeterministic scalar (`random`, the monotonic clock) and buffering output, then replaying
// those exact values — and verifies the two runs are byte-for-byte identical. Returns 0 if the
// replay reproduces the recording (the program is deterministic modulo its captured
// nondeterminism), non-zero otherwise.
int vm_replay(const CompiledProgram *prog, const Tracer *tracer);

#endif // EMBER_VM_H
