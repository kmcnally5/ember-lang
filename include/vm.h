#ifndef EMBER_VM_H
#define EMBER_VM_H

#include "program.h"
#include "trace.h"

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

// After vm_run returns VM_OK, reports whether the program called `exit(code)`. If so,
// returns 1 and writes the code to *code; the driver should terminate with that code
// instead of printing main's return value.
int vm_exited(const VM *vm, int *code);

// Runs the VM. On VM_OK, *out receives the value main returns (valid until
// vm_destroy). On VM_RUNTIME_ERROR (division by zero, overflow, stack/call-depth
// exhaustion) a message is printed to stderr and *out is left untouched. If
// `tracer` is non-NULL, one event fires before each instruction (the tape).
VMResult vm_run(VM *vm, Value *out, const Tracer *tracer);

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
