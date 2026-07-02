#include "vm.h"
#include "opcode.h"
#include "builtin.h"
#include "graphics.h"
#include "cextern.h"
#include "fault.h"      // the unified Fault — a builtin trap reports as a violated implicit
                        // contract with the concrete operand values (docs/faults.md).
#include "ember_rt.h"   // shared runtime: packed marshalling (value_box/unbox, array_box/unbox),
                        // also the C backend's runtime (M2a). The VM is the reference semantics.

#include <stddef.h>   // offsetof (vm_invoke_drop recovers the VM from its embedded EmberRt)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>

#define FRAMES_MAX 256
#define STACK_MAX  4096

// The reference-count primitives (OBJ_RETAIN/OBJ_RELEASE), the EMBER_PARALLEL default,
// the recycle-pool size (POOL_CLASSES), and the EmberRt object-runtime context now live
// in ember_rt.h — authored once and shared with the C backend's runtime (src/runtime.c)
// so the two backends can't drift on them. The parallel build still pulls in pthreads
// directly here for the worker/channel/nursery machinery below.
#if EMBER_PARALLEL
#include <pthread.h>
#endif

// The program's command-line arguments (everything after the source file), set by the
// `run` driver before execution and exposed to Ember via the `args()` builtin. Read-only
// after startup, so it is safe to share across parallel workers. Part of the fixed
// invocation context (like env), so record-replay does not treat it as nondeterminism.
static int          g_prog_argc = 0;
static char       **g_prog_argv = NULL;

void vm_set_program_args(int argc, char **argv) {
    g_prog_argc = argc;
    g_prog_argv = argv;
}

// The entry source path, set by the `run`/`trace` driver before execution and used as a
// Fault's `where.file`. Process-wide like the program args (and, like them, read-only after
// startup, so safe to share across workers). A runtime Fault pairs it with the surfacing
// function name, which disambiguates the multi-module case (per-function source mapping is a
// tracked follow-up — see docs/faults.md).
static const char *g_source_path = NULL;

void vm_set_source_path(const char *path) {
    g_source_path = path;
}

// A call frame: the function executing, its instruction pointer, and the base of
// its locals within the shared value stack.
typedef struct {
    const Function *fn;
    const uint8_t  *ip;
    Value          *slots;
} CallFrame;

// A Fiber owns one task's execution state — its value stack and call frames.
// In the VM (`--emit=run`) concurrency is cooperative N:1: many fibers share one OS
// thread, the VM keeps an "active view" (below) pointing at the current fiber, and a
// context switch repoints that view. (The native `-DEMBER_PARALLEL` build instead runs
// one real OS thread per spawn; neither is the M:N scheduler the manifesto aims at —
// see docs/architecture.md and OFI-071.) For now there is exactly one (the main) fiber.
typedef struct Fiber {
    Value       stack[STACK_MAX];
    CallFrame   frames[FRAMES_MAX];
    Value      *sp;            // saved stack top   (valid while not the active fiber)
    int         frame_count;   // saved frame count
    ObjChannel *block_channel; // non-NULL ⇒ blocked on this channel (else runnable)
    int         block_is_send; // 1 = blocked sending (full), 0 = receiving (empty)
#if EMBER_MN
    // M:N scheduler state. The arena lives HERE (not on the worker VM) so a fiber keeps ONE home no
    // matter which worker runs it — closing the cross-worker free leak structurally. Two intrusive
    // links let a fiber sit on the ready-queue and on a channel waiter FIFO; `fstate` is the single
    // atomic that arbitrates every queue/waiter move (CAS), so a fiber is enqueued exactly once even
    // when a channel wake and a cancel sweep race. `nursery` = the group this fiber is a CHILD of;
    // `cur_open` = the innermost nursery it has OPENED (its parent role), a linked stack via Nursery.
    EmberRt         rt;
    struct Fiber   *qnext;       // ready-queue link
    struct Fiber   *wait_next;   // channel waiter-FIFO link
    struct Fiber   *sib_next;    // sibling link in its nursery's child list (for join + cancel sweep)
    int             fstate;      // FS_READY / FS_RUNNING / FS_PARKED / FS_DONE (via __atomic)
    struct Nursery *nursery;     // the group this fiber belongs to (NULL at top level)
    struct Nursery *cur_open;    // innermost nursery this fiber has opened as a parent
    Value          *out;         // where the main fiber's return value is stored
    int             pin_worker0; // 1 = this fiber resumes ONLY on worker 0 (the calling/GL-context
                                 // thread): the main fiber, so a graphics render loop's teardown
                                 // never lands on a helper thread off the GL context (OFI-138/089)
#endif
} Fiber;

#define MAX_NURSERY_DEPTH 16
#define MAX_GROUP_FIBERS  256

// Recycling pool: dead objects bucketed by block size (16-byte classes), reusing
// each block's own Obj.next as the chain. Hot loops churn small heap values —
// every Some(x), struct instance, map entry, and short string is one allocation —
// and a freelist hit replaces a malloc/free round trip with two pointer moves.
// POOL_CLASSES (the recycle size-class count) is defined in ember_rt.h, shared with the runtime.

// The Heap is the state SHARED across worker threads under the parallel runtime (the
// `-DEMBER_PARALLEL` build runs one OS thread per spawn today — NOT an M:N scheduler;
// see docs/architecture.md and OFI-071): the
// (read-only) program, the intrusive object list, and the recycling pools. Under
// -DEMBER_PARALLEL its mutating accesses (alloc/register/unlink/free) take `lock`;
// HEAP_LOCK is a no-op in the single-threaded default so it costs nothing there.
// Per-worker execution state (the value stack, frames, nursery groups) lives in the
// VM — one VM per worker — so workers never share that, only the heap.
typedef struct {
    const CompiledProgram *prog;
    // Each VM (worker) owns its own object list + pool and uses them lock-free; the
    // heap holds only the shared MERGE TARGET. When a worker finishes it splices its
    // arena in here under `lock` (once per worker, not per object); the exit sweep
    // then frees the graveyard alongside the main VM's own arena. `graveyard`/`gpool`
    // also collect objects deferred by cross-thread frees (left on their home list).
    Obj  *graveyard;               // merged-in object lists, freed on exit
    Obj  *gpool[POOL_CLASSES];     // merged-in recycled blocks, by size class
#if EMBER_PARALLEL
    pthread_mutex_t lock;
#endif
} Heap;

#if EMBER_PARALLEL
#define HEAP_LOCK(h)   pthread_mutex_lock(&(h)->lock)
#define HEAP_UNLOCK(h) pthread_mutex_unlock(&(h)->lock)
#else
#define HEAP_LOCK(h)   ((void)(h))
#define HEAP_UNLOCK(h) ((void)(h))
#endif

#if EMBER_PARALLEL
// Per-nursery deadlock detector. Each task that blocks on a channel registers what
// it is waiting for in slot `i` (its index in the group). When all `total` tasks
// are registered, the last one checks whether ANY of them could actually proceed
// given the current (now-frozen — no task is running) channel state: a parked
// receiver whose channel has data or is closed, or a parked sender whose channel
// has room. If at least one can, it is a signalled-but-not-yet-woken task, not a
// deadlock. Only when NONE can proceed is the group truly stuck — then `deadlocked`
// is set and every channel broadcast so the sleepers wake and error out. This is
// the threaded equivalent of the serial scheduler's "a pass with no runnable fiber"
// rule (it, too, tests channel readiness, not a bare blocked-count).
typedef struct Nursery {
    int             total;
    pthread_mutex_t lock;       // guards the table + nwaiting below
    int             nwaiting;
    int             deadlocked; // atomic — set once, observed by every parked task
    int             sealed;     // 1 once the nursery is closed (all tasks known). With spawn-at-
                                // spawn-time, `total` grows as tasks launch, so deadlock is only
                                // declared after the seal — a not-yet-spawned sibling could unblock.
    ObjChannel     *waits_on[MAX_GROUP_FIBERS];
    int             is_send[MAX_GROUP_FIBERS];
    int             active[MAX_GROUP_FIBERS];   // 1 while task i is parked
#if EMBER_MN
    // M:N accounting (the deadlock VERDICT moves to the Scheduler — it's a global property here).
    int             live;          // children not yet DONE; the last (→0) wakes the parked parent
    struct Fiber   *parent;        // the fiber that opened this nursery (it parks at the close)
    int             parent_parked; // guarded by `lock`
    struct Nursery *enclosing;     // the nursery open when this one began (pop target on close)
    int             cancel;        // set once → siblings unwind cooperatively at yield seams
    int             verdict;       // first non-OK VMResult wins (CAS from VM_OK); the join propagates it
    struct Fiber   *children;      // intrusive list (via Fiber.sib_next) of this group's spawned fibers,
                                   // for the join-time free + the cancel sweep — no fixed cap, so a
                                   // nursery can hold thousands. Children are freed at finalize (after
                                   // live==0), never by finish_child, so the cancel sweep never UAFs.
#endif
} Nursery;
#endif

// Verification loop (§5j, record-replay): the source tags for the captured nondeterministic
// values. Each is a single static address so events can be matched by POINTER (fast, and the
// breakdown is unambiguous). `random`/`clock` yield a double; `read_line`/`read_file` yield a
// string whose bytes are copied into the log so they survive into the (separate) replay run.
static const char NONDET_RANDOM[]    = "random";
static const char NONDET_CLOCK[]     = "clock";
static const char NONDET_READ_LINE[] = "read_line";
static const char NONDET_READ_FILE[] = "read_file";
static const char NONDET_FFI[]       = "ffi";       // a foreign (C) call result leaf

// One captured nondeterministic value, tagged by `kind`: NDV_SCALAR (a double in `num`, from
// random/clock), NDV_STRING (an owned byte copy in `str`/`len`, from read_line/read_file), or
// NDV_FFI (a raw result leaf Value in `val`, from a foreign C call). `src` is a NONDET_* tag.
enum { NDV_SCALAR, NDV_STRING, NDV_FFI };
typedef struct {
    const char *src;
    int         kind;
    double      num;
    char       *str;
    size_t      len;
    Value       val;
} NondetEvent;

struct VM {
    Heap      *heap;        // shared heap (program + merge target + lock)
    // This VM's private allocation arena — its own intrusive object list and
    // size-classed recycling pools — held in the shared EmberRt context so the same
    // allocators/drop serve the C backend (src/runtime.c). Touched only by this VM's
    // thread, so alloc and same-thread free are lock-free; merged into heap->graveyard
    // when the worker ends (the main VM's arena is swept directly at program exit).
#if EMBER_MN
    // M:N: the arena lives in the FIBER (so it follows the fiber across workers — one
    // home regardless of which worker runs it). The worker's VM only POINTS at the
    // running fiber's arena; the dispatcher repoints it alongside the exec view. Every
    // `RT(vm)` / `RT(vm)->X` site is written `RT(vm)` / `RT(vm)->X` (the macro below).
    EmberRt   *active_rt;
#else
    EmberRt    rt;
#endif
    Fiber     *current;     // the fiber the active view reflects
    // Active execution view — points into `current` (push/pop/run use these
    // directly, so they are oblivious to which fiber is running).
    Value     *stack;       // base of the current fiber's value stack
    Value     *sp;          // current stack top
    CallFrame *frames;      // base of the current fiber's frame array
    int        frame_count;
    int        reentry_floor;  // OFI-122: run() returns when frame_count drops to this (0 normally; set
                               // > 0 by vm_invoke_drop so a re-entrant resource `drop` returns to its caller)
    // Nursery group stack: spawned tasks accumulate in the innermost group and
    // are run to completion (and freed) when that nursery's block ends.
    Fiber     *groups[MAX_NURSERY_DEPTH][MAX_GROUP_FIBERS];
    int        group_sizes[MAX_NURSERY_DEPTH];
    int        group_depth;
#if EMBER_PARALLEL && !EMBER_MN
    // Per-nursery run state (1:1 parallel): a spawned task's OS thread starts AT SPAWN (so it runs
    // concurrently with the nursery body — e.g. an event loop that polls it), and the closing
    // brace JOINS. The threads / args / deadlock-group must outlive the body, so they live in a
    // heap NurseryRun allocated at the open and freed at the join. (Serial stays cooperative.)
    struct NurseryRun *runs[MAX_NURSERY_DEPTH];
#endif
#if EMBER_MN
    struct Scheduler *sched;   // the one shared M:N scheduler (ready-queue + worker pool)
#endif
    // Verification loop (§5j, `--check`): when `check_mode` is set, a contract violation does
    // not abort — OP_CONTRACT_CHECK records the message and unwinds so the fuzzer can classify
    // it (a `requires` message ⇒ the input is out of domain; anything else ⇒ a counterexample).
    int          check_mode;
    const char  *check_msg;
    // OFI-108: the `?`-PROPAGATION route — a bounded ring of (fn, line) hops recorded as an Err
    // travels by `?` (OP_ROUTE_HOP fires on the failure branch), so an Err that reaches main shows
    // HOW it propagated even though the frames have unwound by then. Cleared at every CALL (a call
    // cannot occur while a `?` chain unwinds, so it ends any prior — handled — chain), which keeps
    // the buffer to the current chain. Debug-only (OP_ROUTE_HOP is release-elided).
    FaultHop     route_hops[FAULT_MAX_HOPS];
    int          route_hop_count;
    // Verification loop (§5j, record-replay): `nondet_mode` is 0 normal, 1 record (capture each
    // nondeterministic scalar into `nondet_log`), 2 replay (return the recorded values in order;
    // `nondet_diverged` is set if the program asks for a value the recording does not have, i.e.
    // it took a different path). When `capturing`, program output is buffered into `cap_buf`
    // instead of written to stdout, so a record run and a replay run can be compared byte-for-byte.
    int          nondet_mode;
    NondetEvent *nondet_log;
    int          nondet_count;
    int          nondet_cap;
    int          nondet_pos;
    int          nondet_diverged;
    int          capturing;
    char        *cap_buf;
    size_t       cap_len;
    size_t       cap_cap;
    // `exit(code)` requests an immediate, clean halt of the run (no real C exit() here,
    // so a capturing replay/check run can still finish + compare). The OP_CALL_NATIVE
    // handler unwinds the interpreter to VM_OK; the `run` driver performs the real exit.
    int          exit_requested;
    int64_t      exit_code;
#if EMBER_PARALLEL && !EMBER_MN
    // (1:1 parallel) The innermost nursery this fiber runs under (NULL at top level) and this
    // task's slot within it. Channel ops use these to detect deadlock: when every
    // task in a nursery is parked on a channel that cannot progress, no one is left
    // to wake anyone, so the group is stuck (OFI-017). (Under M:N the fiber carries its own
    // `nursery`, and deadlock is a global scheduler property — see the M:N section.)
    Nursery   *nursery;
    int        nursery_slot;
#endif
};

// RT(vm) — the running fiber's object-runtime context, as an EmberRt*. Under M:N the arena lives
// in the fiber (vm->active_rt is repointed per fiber); otherwise it is the VM's embedded `rt`.
// Every allocator/drop call goes through it, so the same code serves both schedulers unchanged.
#if EMBER_MN
#define RT(vm) ((vm)->active_rt)
#else
#define RT(vm) (&(vm)->rt)
#endif

static void runtime_error(const char *msg) {
    fprintf(stderr, "emberc: runtime error: %s\n", msg);
}




// FaultInt is a (name, integer) operand pair handed to runtime_fault. Every builtin trap's
// violating operands (index/len, divisor/dividend, shift/width, …) are live integer C locals
// at the trap, so an int64 list captures them with no Value-boxing and no allocation.
typedef struct {
    const char *name;
    int64_t     v;
    int         is_unsigned;   // render `v`'s bits as u64 (%llu) — for a u64 operand (OFI-110/111c);
                               // default 0 (signed %lld). Most traps' operands are signed i64.
} FaultInt;




// fault_line returns the source line a frame is currently at. A trap/return advances ip past
// the instruction, and a caller frame's ip is its return address, so lines[ip-1] is the site.
static int fault_line(const CallFrame *frame) {
    const Chunk *chunk = &frame->fn->chunk;
    size_t off = (size_t)(frame->ip - chunk->code);
    return chunk->lines != NULL ? chunk->lines[off > 0 ? off - 1 : 0] : 0;
}


// fault_col mirrors fault_line for the source COLUMN of the failing instruction (OFI-111a).
static int fault_col(const CallFrame *frame) {
    const Chunk *chunk = &frame->fn->chunk;
    size_t off = (size_t)(frame->ip - chunk->code);
    return chunk->cols != NULL ? chunk->cols[off > 0 ? off - 1 : 0] : 0;
}




// fault_fill_callstack fills a Fault's primary location (file/fn/line) from `frame` and its
// `route` from the live call stack at this instant (newest frame first) — the synchronous
// backtrace. Shared by every VM fault builder. (The `?`-PROPAGATION route — how an Err
// travelled by `?` after its frames have already returned — is recorded separately, OFI-108.)
static void fault_fill_callstack(Fault *f, VM *vm, const CallFrame *frame) {
    f->file = g_source_path;
    if (frame != NULL) {
        if (frame->fn->source_file != NULL) {   // OFI-111a: the function's true module path
            f->file = frame->fn->source_file;
        }
        f->fn   = frame->fn->name;
        f->line = fault_line(frame);
        f->col  = fault_col(frame);
    }
    int r = 0;
    for (int i = vm->frame_count - 1; i >= 0 && r < FAULT_MAX_HOPS; i--, r++) {
        const CallFrame *fr = &vm->frames[i];
        f->route[r].fn   = fr->fn->name;
        f->route[r].line = fault_line(fr);
    }
    f->route_count = r;
}




// runtime_fault is the structured sibling of runtime_error: it reports a builtin trap as a
// violated IMPLICIT contract (MANIFESTO — a builtin's bound is a contract the LLM should
// restore), carrying the concrete operand values projected from the live frame plus the
// synchronous call-stack route. It assembles a Fault on the (cold) abort path — no hot-path
// cost — and renders it to stderr in the active mode. The operands are read from the C locals
// the caller passes (never the post-pop stack), so a value is never stale or hallucinated.
static void runtime_fault(VM *vm, const CallFrame *frame, const char *code,
                          const char *message, const char *why, const char *hint,
                          const FaultInt *vals, int nvals) {
    // During property-checking (--check) the fuzzer drives many trials and reports
    // counterexamples itself; a per-trial render would be noise. Stay silent and let the
    // trial unwind via VM_RUNTIME_ERROR, mirroring the contract path (OP_CONTRACT_CHECK).
    if (vm->check_mode) {
        return;
    }
    Fault f;
    memset(&f, 0, sizeof f);
    f.severity = FSEV_ERROR;
    f.category = FCAT_RUNTIME;
    f.code     = code;
    f.message  = message;
    f.why      = why;
    f.hint     = hint;
    fault_fill_callstack(&f, vm, frame);

    int n = nvals < FAULT_MAX_VALUES ? nvals : FAULT_MAX_VALUES;
    for (int i = 0; i < n; i++) {
        f.values[i].name = vals[i].name;
        if (vals[i].is_unsigned) {   // a u64 operand renders its bits unsigned, not the i64 view (OFI-110/111c)
            snprintf(f.values[i].rendered, sizeof f.values[i].rendered,
                     "%llu", (unsigned long long)vals[i].v);
        } else {
            snprintf(f.values[i].rendered, sizeof f.values[i].rendered,
                     "%lld", (long long)vals[i].v);
        }
    }
    f.value_count = n;

    fault_render(&f, stderr);
}




// The integer-overflow trap is one implicit contract — "the result must fit the target
// type" — reached from many arithmetic sites (add/sub/mul/div/neg) whose operands differ in
// arity, so these two thin wrappers keep every call site a single statement (so the ARITH
// macro stays clean).
#define OVERFLOW_WHY  "arithmetic requires the result to fit the target integer type"
#define OVERFLOW_HINT "use a wider integer type, or a wrapping operator (wrapping_add/_sub/_mul) for modular arithmetic"

static void overflow_fault(VM *vm, const CallFrame *frame, int64_t lhs, int64_t rhs, int is_unsigned) {
    FaultInt vals[2] = { { "lhs", lhs, is_unsigned }, { "rhs", rhs, is_unsigned } };
    runtime_fault(vm, frame, "integer_overflow", "integer overflow",
                  OVERFLOW_WHY, OVERFLOW_HINT, vals, 2);
}

static void overflow_fault1(VM *vm, const CallFrame *frame, int64_t v, int is_unsigned) {
    FaultInt vals[1] = { { "value", v, is_unsigned } };
    runtime_fault(vm, frame, "integer_overflow", "integer overflow",
                  OVERFLOW_WHY, OVERFLOW_HINT, vals, 1);
}




// contract_fault renders a violated requires/ensures/assert on the unified Fault channel, so
// under --faults=agent a contract violation is agent JSON like a builtin trap (consistency:
// one failure vocabulary). The synthesized message and the `contract_violation` tape event are
// left UNCHANGED, so the --check classifier (which string-matches the message) is untouched.
// Only called outside check_mode (OP_CONTRACT_CHECK returns earlier under check_mode). The
// clause source text as `why` and named param values are a follow-up (OFI-111).
// ---- Fault value walker (OFI-111b) -----------------------------------------
// Render a runtime Value — including structs, enums, and arrays — into a fixed buffer for a
// Fault's values[], so an Err payload shows its data (e.g. MyErr { code: 5 } or NotFound("/x"))
// instead of the old "<obj>". `prog` supplies struct field names + enum variant names (codegen
// preserves them in the CompiledProgram; the parse arena is gone by run time). Depth- and
// budget-bounded; nested strings are quoted but a bare top-level string is not, so the existing
// unhandled-err goldens (whose payloads are top-level strings) stay byte-stable. VM-only — a
// native binary aborts via a bare em_panic by design (OFI-109).
#define FAULT_WALK_MAX_DEPTH 6

typedef struct { char *p; char *end; } FaultSB;   // end = one past the last writable byte (NUL reserved)

static void fsb_raw(FaultSB *sb, const char *s) {
    while (*s != '\0' && sb->p < sb->end) {
        *sb->p++ = *s++;
    }
}

static void fsb_lld(FaultSB *sb, long long v) {
    char t[24];
    snprintf(t, sizeof t, "%lld", v);
    fsb_raw(sb, t);
}

static void fsb_llu(FaultSB *sb, unsigned long long v) {
    char t[24];
    snprintf(t, sizeof t, "%llu", v);
    fsb_raw(sb, t);
}

static void fsb_g(FaultSB *sb, double v) {
    char t[32];
    snprintf(t, sizeof t, "%g", v);
    fsb_raw(sb, t);
}

static const char *fault_variant_name(const CompiledProgram *prog, int enum_id, int tag) {
    for (int i = 0; i < prog->variant_count; i++) {
        if (prog->variants[i].enum_id == enum_id && prog->variants[i].variant_index == tag) {
            return prog->variants[i].name;
        }
    }
    return NULL;
}

static void fault_walk_value(FaultSB *sb, Value v, const CompiledProgram *prog, int depth, int top);

static void fault_walk_struct(FaultSB *sb, const unsigned char *data, int type_id,
                              const CompiledProgram *prog, int depth) {
    if (type_id < 0 || type_id >= prog->struct_count) {
        fsb_raw(sb, "<obj>");
        return;
    }
    if (depth > FAULT_WALK_MAX_DEPTH) {   // guard inline-struct chains too (decoupled from front-end caps)
        fsb_raw(sb, "...");
        return;
    }
    const StructType *st = &prog->structs[type_id];
    fsb_raw(sb, st->name != NULL ? st->name : "?");
    fsb_raw(sb, " {");
    int rendered = 0;
    for (int i = 0; i < st->field_count; i++) {
        const char *fname = st->field_names != NULL ? st->field_names[i] : NULL;
        // A hidden witness field (bounded-generic instance storage) has a NULL name — skip it
        // entirely (name AND value AND separator) so compiler-internal state never leaks into the
        // user-/agent-facing render. A user field always carries a name (OFI-111b).
        if (st->field_names != NULL && fname == NULL) {
            continue;
        }
        fsb_raw(sb, rendered == 0 ? " " : ", ");
        rendered++;
        if (sb->p >= sb->end) {
            break;
        }
        if (fname != NULL) {
            fsb_raw(sb, fname);
            fsb_raw(sb, ": ");
        }
        int kind = st->kind[i];
        const unsigned char *fp = data + st->offset[i];
        if (kind == AEK_INLINE_STRUCT) {
            fault_walk_struct(sb, fp, st->field_struct[i], prog, depth + 1);
        } else if (kind == AEK_BOXED) {
            Value fv;
            memcpy(&fv, fp, sizeof(Value));
            fault_walk_value(sb, fv, prog, depth + 1, 0);
        } else if (kind == AEK_BOOL) {
            Value fv = value_box(fp, kind);
            fsb_raw(sb, AS_INT(fv) != 0 ? "true" : "false");
        } else if (kind == AEK_U64) {
            Value fv = value_box(fp, kind);
            fsb_llu(sb, (unsigned long long)(uint64_t)AS_INT(fv));
        } else {
            Value fv = value_box(fp, kind);
            if (IS_FLOAT(fv)) {
                fsb_g(sb, AS_FLOAT(fv));
            } else {
                fsb_lld(sb, (long long)AS_INT(fv));
            }
        }
    }
    fsb_raw(sb, " }");
}

static void fault_walk_value(FaultSB *sb, Value v, const CompiledProgram *prog, int depth, int top) {
    if (depth > FAULT_WALK_MAX_DEPTH) {
        fsb_raw(sb, "...");
        return;
    }
    if (IS_INT(v)) {
        fsb_lld(sb, (long long)AS_INT(v));
        return;
    }
    if (IS_FLOAT(v)) {
        fsb_g(sb, AS_FLOAT(v));
        return;
    }
    if (IS_STRING(v)) {
        if (!top) {
            fsb_raw(sb, "\"");
        }
        fsb_raw(sb, AS_CSTRING(v));
        if (!top) {
            fsb_raw(sb, "\"");
        }
        return;
    }
    if (IS_ARRAY(v)) {
        ObjArray *a = AS_ARRAY(v);
        fsb_raw(sb, "[");
        for (size_t i = 0; i < a->length; i++) {
            if (i != 0) {
                fsb_raw(sb, ", ");
            }
            if (sb->p >= sb->end) {
                break;
            }
            const unsigned char *ep = (const unsigned char *)a->data + i * a->elem_size;
            if (a->elem_kind == AEK_INLINE_STRUCT) {
                fault_walk_struct(sb, ep, a->elem_struct_id, prog, depth + 1);
            } else {
                Value e = value_box(ep, a->elem_kind);
                fault_walk_value(sb, e, prog, depth + 1, 0);
            }
        }
        fsb_raw(sb, "]");
        return;
    }
    if (IS_STRUCT(v)) {
        ObjStruct *s = AS_STRUCT(v);
        if (s->is_enum) {
            const char *vn = fault_variant_name(prog, s->type_id, s->tag);
            if (vn != NULL) {
                fsb_raw(sb, vn);
            } else {
                fsb_raw(sb, "#");
                fsb_lld(sb, (long long)s->tag);
            }
            if (s->field_count > 0) {
                fsb_raw(sb, "(");
                for (int i = 0; i < s->field_count; i++) {
                    if (i != 0) {
                        fsb_raw(sb, ", ");
                    }
                    if (sb->p >= sb->end) {
                        break;
                    }
                    Value fv;
                    memcpy(&fv, s->data + (size_t)i * sizeof(Value), sizeof(Value));
                    fault_walk_value(sb, fv, prog, depth + 1, 0);
                }
                fsb_raw(sb, ")");
            }
        } else {
            fault_walk_struct(sb, s->data, s->type_id, prog, depth);
        }
        return;
    }
    fsb_raw(sb, "<obj>");   // closures, channels, a Ptr handle, … — no readable form
}

void render_value_into(char *buf, size_t cap, Value v, const CompiledProgram *prog) {
    if (buf == NULL || cap == 0) {
        return;
    }
    FaultSB sb = { buf, buf + cap - 1 };   // reserve the last byte for the NUL
    fault_walk_value(&sb, v, prog, 0, 1);
    *sb.p = '\0';
}


static void contract_fault(VM *vm, const CallFrame *frame, const char *msg) {
    const char *code = "assertion_failed";
    if (strncmp(msg, "precondition", 12) == 0) {
        code = "precondition_failed";
    } else if (strncmp(msg, "postcondition", 13) == 0) {
        code = "postcondition_failed";
    } else if (strncmp(msg, "refinement", 10) == 0) {
        code = "refinement_violation";   // OFI-150
    }
    Fault f;
    memset(&f, 0, sizeof f);
    f.severity = FSEV_ERROR;
    f.category = FCAT_CONTRACT;
    f.code     = code;
    f.message  = msg;
    fault_fill_callstack(&f, vm, frame);
    fault_render(&f, stderr);
}





static int push(VM *vm, Value v) {
    if (vm->sp >= vm->stack + STACK_MAX) {
        runtime_error("stack overflow");
        return 0;
    }
    *vm->sp++ = v;
    return 1;
}





static Value pop(VM *vm) {
    return *--vm->sp;
}





// register_object / pooled_alloc / pooled_free / unlink_object / reclaim moved to
// src/runtime.c (M2a). They take an EmberRt context; the VM calls them with &RT(vm)->






// drop_value (ownership-driven release) and the field_loc / struct_elem_* helpers it
// uses moved to src/runtime.c (M2a). They take an EmberRt and read struct layouts from
// ctx->structs; the VM calls drop_value(RT(vm), v).






// field_loc, field_inline_sid, alloc_instance, make_string moved to src/runtime.c (M2a).


// UTF-8 (Unicode strings, code-point granularity — language.md). The stateless
// utf8_decode/utf8_encode helpers moved to src/runtime.c (M5) so the runtime library
// owns them too (string methods like `.chars()` live there); vm.c picks up their
// declarations from ember_rt.h.






// alloc_interface moved to src/runtime.c (M2a).




// make_closure allocates a function value bound to function table index `fn_index`,
// copying `count` captured values in (and taking its own reference to each heap
// capture, since the capturing scope keeps its own). A bare named function is made
// as a closure with zero captures.
static ObjClosure *make_closure(VM *vm, int fn_index, const Value *captures,
                                int count) {
    ObjClosure *cl = pooled_alloc(RT(vm), sizeof(ObjClosure) + (size_t)count * sizeof(Value));
    cl->obj.type      = OBJ_CLOSURE;
    register_object(RT(vm), (Obj *)cl);
    cl->fn_index      = fn_index;
    cl->capture_count = count;
    for (int i = 0; i < count; i++) {
        Value v = captures[i];
        if (IS_OBJ(v)) {
            OBJ_RETAIN(AS_OBJ(v));   // closure holds its own reference to the capture
        }
        cl->captures[i] = v;
    }
    return cl;
}





// elem_size_for maps an array element kind to its packed width in bytes.
// elem_size_for, value_box, value_unbox now live in include/ember_rt.h (M2a Stage A) —
// the single source of truth for packed scalar marshalling, shared with the C backend.


// unbox_flatten / box_pack convert between a struct's PACKED buffer and the MULTI-SLOT stack
// representation (value-types 3b.5-B): one slot per LEAF scalar, recursing through inline nested
// struct fields. A flat all-scalar struct bottoms out in a single level. unbox_flatten pushes
// the leaves in field/offset order (returns 0 on stack overflow); box_pack pops them back in the
// mirror (reverse) order. (An inline-eligible struct has no AEK_BOXED field, so no refcounting.)
static int unbox_flatten(VM *vm, int sid, const unsigned char *base) {
    const StructType *st = &vm->heap->prog->structs[sid];
    for (int f = 0; f < st->field_count; f++) {
        if (st->field_struct[f] >= 0) {
            if (!unbox_flatten(vm, st->field_struct[f], base + st->offset[f])) {
                return 0;
            }
        } else if (!push(vm, value_box(base + st->offset[f], st->kind[f]))) {
            return 0;
        }
    }
    return 1;
}






// Like unbox_flatten, but for a BORROWED struct (a named local passed by value to a multi-slot
// param): the SOURCE keeps ownership, so each heap leaf is RETAINED as it is copied onto the stack
// (the callee's param later releases it), and the caller does NOT reclaim the shell. Mirrors
// struct_elem_retain but recursing through inline nested struct fields like unbox_flatten (OFI-058).
static int unbox_flatten_borrow(VM *vm, int sid, const unsigned char *base) {
    const StructType *st = &vm->heap->prog->structs[sid];
    for (int f = 0; f < st->field_count; f++) {
        if (st->field_struct[f] >= 0) {
            if (!unbox_flatten_borrow(vm, st->field_struct[f], base + st->offset[f])) {
                return 0;
            }
        } else {
            Value v = value_box(base + st->offset[f], st->kind[f]);
            if (IS_OBJ(v)) {
                OBJ_RETAIN(AS_OBJ(v));   // borrow: the source local still owns this leaf too
            }
            if (!push(vm, v)) {
                return 0;
            }
        }
    }
    return 1;
}

static void box_pack(VM *vm, int sid, unsigned char *base) {
    const StructType *st = &vm->heap->prog->structs[sid];
    for (int f = st->field_count - 1; f >= 0; f--) {
        if (st->field_struct[f] >= 0) {
            box_pack(vm, st->field_struct[f], base + st->offset[f]);
        } else {
            value_unbox(base + st->offset[f], st->kind[f], pop(vm));
        }
    }
}


// pack_from_buf packs a struct's leaves from a forward Value buffer (`buf[*idx]` in field/leaf
// order), recursing through inline nested fields — used to reassemble an Ember struct from a C
// wrapper's flattened result leaves (FFI structs-by-value, 3b.6).
static void pack_from_buf(VM *vm, int sid, unsigned char *base, const Value *buf, int *idx) {
    const StructType *st = &vm->heap->prog->structs[sid];
    for (int f = 0; f < st->field_count; f++) {
        if (st->field_struct[f] >= 0) {
            pack_from_buf(vm, st->field_struct[f], base + st->offset[f], buf, idx);
        } else {
            value_unbox(base + st->offset[f], st->kind[f], buf[(*idx)++]);
        }
    }
}

// struct_elem_retain / struct_elem_release and alloc_array / alloc_slice /
// alloc_struct_array moved to src/runtime.c (M2a). The packed marshalling edge
// (value_box / value_unbox / array_box / array_unbox / elem_size_for) is inline in
// include/ember_rt.h, shared by both backends.





// alloc_channel allocates a buffered channel (capacity `cap`) on the shared heap.
static Value alloc_channel(VM *vm, int cap) {
    // Pooled like every other heap object (was raw-malloc'd back when channels were never
    // reclaimed): now a channel is refcounted and its shell returns to the size-class pool on
    // the last drop, so it MUST carry a valid size_class — only pooled_alloc sets that.
    ObjChannel *ch = pooled_alloc(RT(vm), sizeof(ObjChannel));
    Value *buf = malloc((cap > 0 ? (size_t)cap : 1) * sizeof(Value));
    if (buf == NULL) {
        fprintf(stderr, "emberc: out of memory allocating a channel\n");
        exit(70);
    }
    ch->obj.type = OBJ_CHANNEL;
    register_object(RT(vm), (Obj *)ch);
    ch->buffer   = buf;
    ch->capacity = cap > 0 ? cap : 1;
    ch->count    = 0;
    ch->head     = 0;
    ch->closed   = 0;
#if EMBER_MN
    pthread_mutex_init(&ch->lock, NULL);
    ch->recv_head = NULL;
    ch->recv_tail = NULL;
    ch->send_head = NULL;
    ch->send_tail = NULL;
#elif EMBER_PARALLEL
    pthread_mutex_init(&ch->lock, NULL);
    pthread_cond_init(&ch->not_empty, NULL);
    pthread_cond_init(&ch->not_full, NULL);
    ch->recv_waiters = 0;
    ch->send_waiters = 0;
#endif
    return OBJ_VAL(ch);
}





// free_list / drain_pool moved to src/runtime.c (M2a) — shared by the VM's exit sweep
// (free_objects, below) and a generated binary's (rt_free_objects).

// The single-threaded exit sweep: free the main VM's own arena plus the graveyard
// every finished worker merged into (which also holds objects deferred by
// cross-thread frees). By now all workers have joined, so this needs no lock.
static void free_objects(VM *vm) {
#if EMBER_MN
    // M:N: every fiber (incl. main) drained its pool and merged its surviving objects into the shared
    // graveyard when it retired, and the worker VMs own no arena — so the exit sweep is just the
    // graveyard + the merged pools. (vm->active_rt dangles here: main's arena was freed at retire.)
    free_list(vm->heap->graveyard);
    vm->heap->graveyard = NULL;
    drain_pool(vm->heap->gpool);
#else
    free_list(RT(vm)->objects);
    RT(vm)->objects = NULL;
    free_list(vm->heap->graveyard);
    vm->heap->graveyard = NULL;
    drain_pool(RT(vm)->pool);
    drain_pool(vm->heap->gpool);
#endif
}





// Overflow bounds per numeric kind, matching the checker's int_kind ordering:
//   0 i64, 1 i8, 2 i16, 3 i32, 4 u8, 5 u16, 6 u32.
// An integer arithmetic result must land within [NK_MIN, NK_MAX] for its operand
// width or it traps — the same defined-overflow guarantee `int` (i64) already has.
static const int64_t NK_MIN[7] = {
    INT64_MIN, -128, -32768, -2147483648LL, 0, 0, 0
};
static const int64_t NK_MAX[7] = {
    INT64_MAX, 127, 32767, 2147483647LL, 255, 65535, 4294967295LL
};

// nk_bits maps a numeric kind to its integer width in bits (for the shift ops).
// 0 i64 / 7 u64 → 64; i8/u8 → 8; i16/u16 → 16; i32/u32 → 32.
static inline int nk_bits(uint8_t nk) {
    switch (nk) {
        case 1: case 4: return 8;
        case 2: case 5: return 16;
        case 3: case 6: return 32;
        default:        return 64;   // 0 (i64), 7 (u64)
    }
}

// ARITH performs a binary +/-/*: float arithmetic when the operands are floats,
// otherwise integer arithmetic that *traps* on overflow (OFI-005). The operand
// byte `nk` is the numeric kind; the int result is range-checked to its width.
// The checker guarantees both operands share a type, so testing one suffices.
// otherwise integer arithmetic that *traps* on overflow (OFI-005). The operand
// byte `nk` is the numeric kind: kind 7 (u64) is unsigned and wrap-traps at 2^64;
// kind 8 (f32) rounds the float result to 32-bit; kinds 0..6 range-check the
// signed result to their width. The checker guarantees both operands share a type.
#define ARITH(builtin, fop)                                              \
    do {                                                                 \
        uint8_t nk = *frame->ip++;                                       \
        Value vb = pop(vm);                                              \
        Value va = pop(vm);                                              \
        if (IS_INT(va) && nk == 0) {                                     \
            /* The common case — plain i64 — skips the width-bounds      \
               table; i64's bounds are the overflow check itself. */     \
            int64_t r;                                                   \
            if (builtin(AS_INT(va), AS_INT(vb), &r)) {                   \
                overflow_fault(vm, frame, AS_INT(va), AS_INT(vb), nk == 7);             \
                return VM_RUNTIME_ERROR;                                 \
            }                                                            \
            if (!push(vm, INT_VAL(r))) {                                 \
                return VM_RUNTIME_ERROR;                                 \
            }                                                            \
        } else if (IS_FLOAT(va)) {                                       \
            double fr = AS_FLOAT(va) fop AS_FLOAT(vb);                   \
            if (nk == 8) { fr = (float)fr; }                            \
            if (!push(vm, FLOAT_VAL(fr))) {                             \
                return VM_RUNTIME_ERROR;                                 \
            }                                                            \
        } else if (nk == 7) {                                            \
            uint64_t ur;                                                 \
            if (builtin((uint64_t)AS_INT(va), (uint64_t)AS_INT(vb),      \
                        &ur)) {                                          \
                overflow_fault(vm, frame, AS_INT(va), AS_INT(vb), nk == 7);             \
                return VM_RUNTIME_ERROR;                                 \
            }                                                            \
            if (!push(vm, INT_VAL((int64_t)ur))) {                      \
                return VM_RUNTIME_ERROR;                                 \
            }                                                            \
        } else {                                                         \
            int64_t r;                                                   \
            if (builtin(AS_INT(va), AS_INT(vb), &r) ||                   \
                r < NK_MIN[nk] || r > NK_MAX[nk]) {                      \
                overflow_fault(vm, frame, AS_INT(va), AS_INT(vb), nk == 7);             \
                return VM_RUNTIME_ERROR;                                 \
            }                                                            \
            if (!push(vm, INT_VAL(r))) {                                 \
                return VM_RUNTIME_ERROR;                                 \
            }                                                            \
        }                                                                \
    } while (0)

// WRAP performs a +/-/* that WRAPS modulo 2^width instead of trapping (OFI-041): the
// explicit `wrapping_add`/`wrapping_sub`/`wrapping_mul` builtins, for hashes/PRNGs/
// checksums that depend on modular arithmetic. Integer-only (the checker rejects floats).
// The arithmetic is done in uint64_t (defined wraparound at 2^64), then the result is
// truncated to the kind's width and reinterpreted — sign-extended for the signed kinds.
#define WRAP(op)                                                         \
    do {                                                                 \
        uint8_t nk = *frame->ip++;                                       \
        Value vb = pop(vm);                                              \
        Value va = pop(vm);                                              \
        uint64_t ur = (uint64_t)AS_INT(va) op (uint64_t)AS_INT(vb);      \
        int64_t r;                                                       \
        switch (nk) {                                                    \
            case 1: r = (int8_t)(ur & 0xFFu);          break; /* i8  */  \
            case 2: r = (int16_t)(ur & 0xFFFFu);       break; /* i16 */  \
            case 3: r = (int32_t)(ur & 0xFFFFFFFFu);   break; /* i32 */  \
            case 4: r = (int64_t)(ur & 0xFFu);         break; /* u8  */  \
            case 5: r = (int64_t)(ur & 0xFFFFu);       break; /* u16 */  \
            case 6: r = (int64_t)(ur & 0xFFFFFFFFu);   break; /* u32 */  \
            default: r = (int64_t)ur;                  break; /* i64/u64 */ \
        }                                                                \
        if (!push(vm, INT_VAL(r))) {                                     \
            return VM_RUNTIME_ERROR;                                     \
        }                                                                \
    } while (0)

// COMPARE performs an ordering op (the operand byte is the numeric kind, so kind 7
// compares the int64 bits as unsigned u64); the result is a bool (int 0/1).
#define COMPARE(cop)                                                     \
    do {                                                                 \
        uint8_t nk = *frame->ip++;                                       \
        Value vb = pop(vm);                                              \
        Value va = pop(vm);                                              \
        int res;                                                         \
        if (IS_FLOAT(va)) {                                              \
            res = (AS_FLOAT(va) cop AS_FLOAT(vb));                       \
        } else if (nk == 7) {                                            \
            res = ((uint64_t)AS_INT(va) cop (uint64_t)AS_INT(vb));       \
        } else {                                                         \
            res = (AS_INT(va) cop AS_INT(vb));                           \
        }                                                                \
        if (!push(vm, INT_VAL(res ? 1 : 0))) {                          \
            return VM_RUNTIME_ERROR;                                     \
        }                                                                \
    } while (0)

// vm_out writes program output: to stdout normally, or into the VM's capture buffer when a
// record/replay run is comparing the two executions byte-for-byte (§5j). Grows the buffer as
// needed (kept NUL-terminatable for cheap string compares).
static void vm_out(VM *vm, const char *s, size_t n) {
    if (!vm->capturing) {
        fwrite(s, 1, n, stdout);
        return;
    }
    if (vm->cap_len + n + 1 > vm->cap_cap) {
        size_t want = vm->cap_cap ? vm->cap_cap : 256;
        while (vm->cap_len + n + 1 > want) {
            want *= 2;
        }
        vm->cap_buf = realloc(vm->cap_buf, want);
        if (vm->cap_buf == NULL) {
            fprintf(stderr, "emberc: out of memory capturing output\n");
            exit(70);
        }
        vm->cap_cap = want;
    }
    memcpy(vm->cap_buf + vm->cap_len, s, n);
    vm->cap_len += n;
    vm->cap_buf[vm->cap_len] = '\0';
}

// nondet_scalar threads a nondeterministic scalar through record-replay (§5j). Normal mode returns
// the real value; record mode also appends it to the log; replay mode returns the next recorded
// value for this source instead (and flags divergence if the program's demand no longer matches
// the recording). `src` is a static tag, compared by pointer.
// nondet_append reserves and returns the next log slot (record mode), growing the buffer.
static NondetEvent *nondet_append(VM *vm) {
    if (vm->nondet_count == vm->nondet_cap) {
        vm->nondet_cap = vm->nondet_cap ? vm->nondet_cap * 2 : 16;
        vm->nondet_log = realloc(vm->nondet_log, (size_t)vm->nondet_cap * sizeof(NondetEvent));
        if (vm->nondet_log == NULL) {
            fprintf(stderr, "emberc: out of memory recording nondeterminism\n");
            exit(70);
        }
    }
    return &vm->nondet_log[vm->nondet_count++];
}

static double nondet_scalar(VM *vm, const char *src, double real) {
    if (vm->nondet_mode == 1) {
        NondetEvent *e = nondet_append(vm);
        e->src = src;  e->kind = NDV_SCALAR;  e->num = real;  e->str = NULL;  e->len = 0;
        return real;
    }
    if (vm->nondet_mode == 2) {
        NondetEvent *e = vm->nondet_pos < vm->nondet_count ? &vm->nondet_log[vm->nondet_pos] : NULL;
        if (e != NULL && e->src == src && e->kind == NDV_SCALAR) {
            vm->nondet_pos++;
            return e->num;
        }
        vm->nondet_diverged = 1;
        return real;
    }
    return real;
}


// nondet_record_ffi captures one scalar leaf a foreign (C) call returned, so the call can be
// replayed without re-invoking C (whose result — time, rand, hardware — may differ each run).
static void nondet_record_ffi(VM *vm, Value leaf) {
    NondetEvent *e = nondet_append(vm);
    e->src = NONDET_FFI;  e->kind = NDV_FFI;  e->val = leaf;  e->str = NULL;  e->len = 0;
}


// nondet_replay_ffi returns the next recorded foreign-call result leaf (replay mode), or flags
// divergence and returns 0 if the recording no longer matches the program's demand.
static Value nondet_replay_ffi(VM *vm) {
    NondetEvent *e = vm->nondet_pos < vm->nondet_count ? &vm->nondet_log[vm->nondet_pos] : NULL;
    if (e != NULL && e->src == NONDET_FFI && e->kind == NDV_FFI) {
        vm->nondet_pos++;
        return e->val;
    }
    vm->nondet_diverged = 1;
    return INT_VAL(0);
}

// nondet_record_string captures the bytes of a string a source just produced (record mode),
// copying them so they outlive this run and can be replayed in the separate replay run.
static void nondet_record_string(VM *vm, const char *src, ObjString *s) {
    NondetEvent *e = nondet_append(vm);
    e->src = src;  e->kind = NDV_STRING;  e->num = 0;  e->len = s->length;
    e->str = malloc(s->length + 1);
    if (e->str == NULL) {
        fprintf(stderr, "emberc: out of memory recording nondeterminism\n");
        exit(70);
    }
    memcpy(e->str, s->chars, s->length);
    e->str[s->length] = '\0';
}

// nondet_replay_string returns a fresh ObjString (in THIS vm's heap) holding the next recorded
// value for `src`, or an empty string with the divergence flag set if the recording no longer
// matches what the program asks for. Used so a replay run performs no real I/O.
static Value nondet_replay_string(VM *vm, const char *src) {
    if (vm->nondet_pos < vm->nondet_count && vm->nondet_log[vm->nondet_pos].src == src &&
        vm->nondet_log[vm->nondet_pos].kind == NDV_STRING) {
        NondetEvent *e = &vm->nondet_log[vm->nondet_pos++];
        ObjString *s = make_string(RT(vm), e->len);
        memcpy(s->chars, e->str, e->len);
        return OBJ_VAL(s);
    }
    vm->nondet_diverged = 1;
    return OBJ_VAL(make_string(RT(vm), 0));
}

// print_value writes a value in its surface form through vm_out. The checker only lets
// int/float/string reach a print, but the others are handled defensively.
static void print_value(VM *vm, Value v) {
    char buf[32];
    if (IS_INT(v)) {
        vm_out(vm, buf, (size_t)snprintf(buf, sizeof buf, "%lld", (long long)AS_INT(v)));
    } else if (IS_FLOAT(v)) {
        vm_out(vm, buf, (size_t)snprintf(buf, sizeof buf, "%g", AS_FLOAT(v)));
    } else if (IS_STRING(v)) {
        vm_out(vm, AS_CSTRING(v), strlen(AS_CSTRING(v)));
    } else {
        vm_out(vm, "<obj>", 5);
    }
}





// call_native dispatches a built-in. print/println write their argument; the I/O
// natives read/write stdin and files and return a string (the result is a unit
// placeholder for the statement-only ones). Allocating natives use the VM.
static Value call_native(VM *vm, int native_id, Value *args, int argc) {
    switch (native_id) {
        case NATIVE_PRINT:
        case NATIVE_PRINTLN: {
            Value arg = argc >= 1 ? args[0] : INT_VAL(0);
            print_value(vm, arg);
            if (native_id == NATIVE_PRINTLN) {
                vm_out(vm, "\n", 1);
            }
            return INT_VAL(0);
        }
        case NATIVE_READ_LINE: {
            // One line of stdin, without the newline. Empty string at end of input.
            if (vm->nondet_mode == 2) {   // replay: return the recorded line, no real read
                return nondet_replay_string(vm, NONDET_READ_LINE);
            }
            size_t cap = 128, len = 0;
            char *buf = malloc(cap);
            if (buf == NULL) {
                return OBJ_VAL(make_string(RT(vm), 0));
            }
            int ch, any = 0;
            while ((ch = fgetc(stdin)) != EOF) {
                any = 1;
                if (ch == '\n') {
                    break;
                }
                if (len + 1 >= cap) {
                    cap *= 2;
                    char *nb = realloc(buf, cap);
                    if (nb == NULL) { break; }
                    buf = nb;
                }
                buf[len++] = (char)ch;
            }
            (void)any;
            if (len > 0 && buf[len - 1] == '\r') {   // tolerate CRLF
                len--;
            }
            ObjString *s = make_string(RT(vm), len);
            memcpy(s->chars, buf, len);
            free(buf);
            if (vm->nondet_mode == 1) {   // record the line for a future replay
                nondet_record_string(vm, NONDET_READ_LINE, s);
            }
            return OBJ_VAL(s);
        }
        case NATIVE_READ_FILE: {
            if (vm->nondet_mode == 2) {   // replay: return the recorded contents, no real read
                return nondet_replay_string(vm, NONDET_READ_FILE);
            }
            const char *path = argc >= 1 ? AS_CSTRING(args[0]) : "";
            FILE *f = fopen(path, "rb");
            ObjString *s;
            long sz = -1;
            if (f != NULL) {
                fseek(f, 0, SEEK_END);
                sz = ftell(f);
                fseek(f, 0, SEEK_SET);
            }
            if (f == NULL || sz < 0) {
                s = make_string(RT(vm), 0);     // unreadable: empty (recorded so replay matches)
            } else {
                char *buf = malloc((size_t)sz + 1);
                size_t got = (buf != NULL) ? fread(buf, 1, (size_t)sz, f) : 0;
                s = make_string(RT(vm), got);
                if (buf != NULL) {
                    memcpy(s->chars, buf, got);
                    free(buf);
                }
            }
            if (f != NULL) {
                fclose(f);
            }
            if (vm->nondet_mode == 1) {   // record the contents for a future replay
                nondet_record_string(vm, NONDET_READ_FILE, s);
            }
            return OBJ_VAL(s);
        }
        case NATIVE_WRITE_FILE: {
            if (vm->nondet_mode == 2) {   // replay performs no real I/O — skip the write
                return INT_VAL(0);
            }
            const char *path = argc >= 1 ? AS_CSTRING(args[0]) : "";
            FILE *f = fopen(path, "wb");
            if (f != NULL) {
                if (argc >= 2) {
                    ObjString *content = AS_STRING(args[1]);
                    fwrite(content->chars, 1, content->length, f);
                }
                fclose(f);
            }
            return INT_VAL(0);
        }
        case NATIVE_CHAR_CODE: {
            // The first Unicode CODE POINT (UTF-8 decoded), not the first byte. −1 if empty.
            ObjString *s = argc >= 1 ? AS_STRING(args[0]) : NULL;
            if (s == NULL || s->length == 0) {
                return INT_VAL(-1);
            }
            uint32_t cp;
            utf8_decode((const unsigned char *)s->chars, s->length, &cp);
            return INT_VAL((int64_t)cp);
        }
        case NATIVE_FROM_CHAR_CODE: {
            // UTF-8 ENCODE a code point to a 1–4-byte string (out-of-range/surrogate → U+FFFD).
            int64_t n = argc >= 1 ? AS_INT(args[0]) : 0;
            unsigned char buf[4];
            int w = utf8_encode((n < 0 || n > 0x10FFFF) ? 0xFFFDu : (uint32_t)n, buf);
            ObjString *s = make_string(RT(vm), (size_t)w);
            memcpy(s->chars, buf, (size_t)w);
            return OBJ_VAL(s);
        }
        case NATIVE_BYTE_SLICE: {
            // byte_slice(s, start, end) -> the raw bytes [start, end) of s as a string. BYTE-indexed
            // (not code-point), so it faithfully preserves multi-byte UTF-8 — the exact-lexeme
            // primitive the self-hosted lexer needs. Out-of-range bounds clamp; start>end is empty.
            ObjString *s = argc >= 1 ? AS_STRING(args[0]) : NULL;
            int64_t len = s ? (int64_t)s->length : 0;
            int64_t lo  = argc >= 2 ? AS_INT(args[1]) : 0;
            int64_t hi  = argc >= 3 ? AS_INT(args[2]) : 0;
            if (lo < 0)   { lo = 0; }
            if (hi > len) { hi = len; }
            if (lo > hi)  { lo = hi; }
            size_t n = (size_t)(hi - lo);
            ObjString *out = make_string(RT(vm), n);
            if (n > 0) { memcpy(out->chars, s->chars + lo, n); }
            return OBJ_VAL(out);
        }
        case NATIVE_FROM_BYTES: {
            // from_bytes(bytes) -> a string whose raw buffer is EXACTLY the [u8] array's bytes. The inverse
            // of .bytes(): no UTF-8 re-encoding (unlike from_char_code), so it can build ANY byte sequence
            // — the primitive an Ember-side binary serializer needs (docs/design/bytecode-container.md).
            // A [u8] array packs one byte per element (AEK_U8), copied directly; any other integer packing
            // is read element-by-element and masked to a byte, so the builtin is representation-robust.
            ObjArray *a = argc >= 1 ? AS_ARRAY(args[0]) : NULL;
            size_t n = a ? a->length : 0;
            ObjString *out = make_string(RT(vm), n);
            if (n > 0) {
                if (a->elem_kind == AEK_U8) {
                    memcpy(out->chars, a->data, n);
                } else {
                    for (size_t i = 0; i < n; i++) {
                        out->chars[i] = (char)(AS_INT(em_index(RT(vm), OBJ_VAL(a), INT_VAL((int64_t)i))) & 0xFF);
                    }
                }
            }
            return OBJ_VAL(out);
        }
        case NATIVE_PARSE_FLOAT: {
            const char *str = argc >= 1 ? AS_CSTRING(args[0]) : "";
            return FLOAT_VAL(strtod(str, NULL));
        }
        case NATIVE_SQRT:  return FLOAT_VAL(sqrt(AS_FLOAT(args[0])));
        case NATIVE_POW:   return FLOAT_VAL(pow(AS_FLOAT(args[0]), AS_FLOAT(args[1])));
        case NATIVE_ABS:   return FLOAT_VAL(fabs(AS_FLOAT(args[0])));
        case NATIVE_FLOOR: return FLOAT_VAL(floor(AS_FLOAT(args[0])));
        case NATIVE_CEIL:  return FLOAT_VAL(ceil(AS_FLOAT(args[0])));
        case NATIVE_ROUND: return FLOAT_VAL(round(AS_FLOAT(args[0])));
        case NATIVE_RANDOM:
            return FLOAT_VAL(nondet_scalar(vm, NONDET_RANDOM,
                                           (double)rand() / ((double)RAND_MAX + 1.0)));
        case NATIVE_HASH: {
            // FNV-1a over the bytes, sign bit cleared so the result is a
            // non-negative int the stdlib can `% capacity` without trapping.
            ObjString *s = argc >= 1 ? AS_STRING(args[0]) : NULL;
            uint64_t h = 1469598103934665603ULL;   // FNV-1a offset basis
            if (s != NULL) {
                for (size_t i = 0; i < s->length; i++) {
                    h ^= (unsigned char)s->chars[i];
                    h *= 1099511628211ULL;          // FNV-1a prime
                }
            }
            return INT_VAL((int64_t)(h & 0x7fffffffffffffffULL));
        }
        case NATIVE_CONCAT: {
            // Join a [string] (a boxed array of ObjStrings) into one string with a
            // single allocation and one copy pass — the linear builder the stdlib
            // uses instead of repeated `out = out + c` (which is O(n^2)).
            ObjArray *a = argc >= 1 ? AS_ARRAY(args[0]) : NULL;
            if (a == NULL || a->length == 0) {
                return OBJ_VAL(make_string(RT(vm), 0));
            }
            const Value *parts = (const Value *)a->data;
            size_t total = 0;
            for (size_t i = 0; i < a->length; i++) {
                total += AS_STRING(parts[i])->length;
            }
            ObjString *r = make_string(RT(vm), total);
            size_t off = 0;
            for (size_t i = 0; i < a->length; i++) {
                ObjString *p = AS_STRING(parts[i]);
                memcpy(r->chars + off, p->chars, p->length);
                off += p->length;
            }
            return OBJ_VAL(r);
        }
        case NATIVE_ARGS: {
            // The program's command-line arguments as a fresh [string]. Part of the
            // fixed invocation context, so no record/replay (like env): a replay reruns
            // the same invocation. Each arg is copied into an owned ObjString.
            Value arr = alloc_array(RT(vm), (size_t)g_prog_argc, AEK_BOXED);
            Value *elems = (Value *)AS_ARRAY(arr)->data;
            for (int i = 0; i < g_prog_argc; i++) {
                size_t len = strlen(g_prog_argv[i]);
                ObjString *s = make_string(RT(vm), len);
                memcpy(s->chars, g_prog_argv[i], len);
                elems[i] = OBJ_VAL(s);
            }
            return arr;
        }
        case NATIVE_ENV: {
            const char *name = argc >= 1 ? AS_CSTRING(args[0]) : "";
            const char *val  = getenv(name);
            if (val == NULL) {
                return OBJ_VAL(make_string(RT(vm), 0));   // unset: empty string
            }
            size_t len = strlen(val);
            ObjString *s = make_string(RT(vm), len);
            memcpy(s->chars, val, len);
            return OBJ_VAL(s);
        }
        case NATIVE_EXIT: {
            // Request a clean halt rather than calling C exit() here, so a capturing
            // replay/check run still finishes and the `run` driver controls the real exit.
            vm->exit_requested = 1;
            vm->exit_code      = argc >= 1 ? AS_INT(args[0]) : 0;
            return INT_VAL(0);
        }
        case NATIVE_HASH_ANY: {
            // Hash any built-in key Value (Map<K,V> with a scalar/string key). A string
            // hashes by FNV-1a over its bytes; an int/bool by mixing its 64-bit payload.
            // Sign bit cleared so the result is a non-negative int (`% capacity` is safe).
            Value v = argc >= 1 ? args[0] : INT_VAL(0);
            uint64_t h;
            if (IS_STRING(v)) {
                ObjString *s = AS_STRING(v);
                h = 1469598103934665603ULL;
                for (size_t i = 0; i < s->length; i++) {
                    h ^= (unsigned char)s->chars[i];
                    h *= 1099511628211ULL;
                }
            } else {
                uint64_t x = (uint64_t)AS_INT(v);   // int / bool payload
                x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33;
                h = x;
            }
            return INT_VAL((int64_t)(h & 0x7fffffffffffffffULL));
        }
        case NATIVE_VALUE_EQ: {
            // Structural equality of two built-in key Values: strings by bytes, others
            // by their 64-bit payload (int/bool). Returns a bool (int 0/1).
            Value a = argc >= 1 ? args[0] : INT_VAL(0);
            Value b = argc >= 2 ? args[1] : INT_VAL(0);
            int eq;
            if (IS_STRING(a) && IS_STRING(b)) {
                ObjString *sa = AS_STRING(a), *sb = AS_STRING(b);
                eq = sa->length == sb->length &&
                     memcmp(sa->chars, sb->chars, sa->length) == 0;
            } else {
                eq = AS_INT(a) == AS_INT(b);
            }
            return INT_VAL(eq ? 1 : 0);
        }
#if EMBER_GRAPHICS
        // Graphics primitives (MANIFESTO §5g) — dispatch to the isolated backend.
        // The checker has validated arity/types, so the arguments are as expected.
        case NATIVE_GFX_WINDOW_OPEN:
            ember_gfx_window_open((int)AS_INT(args[0]), (int)AS_INT(args[1]),
                                  AS_CSTRING(args[2]));
            return INT_VAL(0);
        case NATIVE_GFX_WINDOW_CLOSE:
            ember_gfx_window_close();
            return INT_VAL(0);
        case NATIVE_GFX_SHOULD_CLOSE:
            return INT_VAL(ember_gfx_should_close());
        case NATIVE_GFX_SET_EVENT_WAIT:
            ember_gfx_set_event_waiting((int)AS_INT(args[0]));
            return INT_VAL(0);
        case NATIVE_GFX_HAD_INPUT:
            return INT_VAL(ember_gfx_had_input());
        case NATIVE_GFX_MEASURE_MISSES:
            return INT_VAL(ember_gfx_measure_misses());
        case NATIVE_GFX_FRAME_STEPS:
            return INT_VAL(ember_gfx_frame_steps());
        case NATIVE_GFX_SET_ALPHA:
            ember_gfx_set_alpha((int)AS_INT(args[0]));
            return INT_VAL(0);
        case NATIVE_GFX_FRAME_BEGIN:
            ember_gfx_frame_begin((int)AS_INT(args[0]));
            return INT_VAL(0);
        case NATIVE_GFX_FRAME_END:
            ember_gfx_frame_end();
            return INT_VAL(0);
        case NATIVE_GFX_DRAW_RECT:
            ember_gfx_draw_rect((int)AS_INT(args[0]), (int)AS_INT(args[1]),
                                (int)AS_INT(args[2]), (int)AS_INT(args[3]),
                                (int)AS_INT(args[4]));
            return INT_VAL(0);
        case NATIVE_GFX_DRAW_TEXT:
            ember_gfx_draw_text(AS_CSTRING(args[0]), (int)AS_INT(args[1]),
                                (int)AS_INT(args[2]), (int)AS_INT(args[3]),
                                (int)AS_INT(args[4]));
            return INT_VAL(0);
        case NATIVE_GFX_KEY_DOWN:
            return INT_VAL(ember_gfx_key_down((int)AS_INT(args[0])));
        case NATIVE_GFX_MOUSE_X:
            return INT_VAL(ember_gfx_mouse_x());
        case NATIVE_GFX_MOUSE_Y:
            return INT_VAL(ember_gfx_mouse_y());
        case NATIVE_GFX_MOUSE_DOWN:
            return INT_VAL(ember_gfx_mouse_down());
        case NATIVE_GFX_MOUSE_RDOWN:
            return INT_VAL(ember_gfx_mouse_right_down());
        case NATIVE_GFX_MEASURE_TEXT:
            return INT_VAL(ember_gfx_measure_text(AS_CSTRING(args[0]),
                                                  (int)AS_INT(args[1])));
        case NATIVE_GFX_TEXT_LINE_H:
            return INT_VAL(ember_gfx_text_line_height((int)AS_INT(args[0])));
        case NATIVE_GFX_CHAR_PRESSED:
            return INT_VAL(ember_gfx_char_pressed());
        case NATIVE_GFX_KEY_PRESSED:
            return INT_VAL(ember_gfx_key_pressed((int)AS_INT(args[0])));
        case NATIVE_GFX_KEY_REPEAT:
            return INT_VAL(ember_gfx_key_repeat((int)AS_INT(args[0])));
        case NATIVE_GFX_LOAD_FONT:
            return INT_VAL(ember_gfx_load_font(AS_CSTRING(args[0])));
        case NATIVE_GFX_SET_FONT:
            ember_gfx_set_font((int)AS_INT(args[0]));
            return INT_VAL(0);
        case NATIVE_GFX_SET_CURSOR:
            ember_gfx_set_cursor((int)AS_INT(args[0]));
            return INT_VAL(0);
        case NATIVE_GFX_CLIPBOARD_SET:
            ember_gfx_clipboard_set(AS_CSTRING(args[0]));
            return INT_VAL(0);
        case NATIVE_GFX_CLIPBOARD_GET: {
            const char *cb = ember_gfx_clipboard_get();
            size_t cblen = (cb != NULL) ? strlen(cb) : 0;
            ObjString *cbs = make_string(RT(vm), cblen);
            if (cblen > 0) {
                memcpy(cbs->chars, cb, cblen);
            }
            return OBJ_VAL(cbs);
        }
        case NATIVE_GFX_DROPPED_FILES: {
            const char *df = ember_gfx_dropped_files();
            size_t dflen = (df != NULL) ? strlen(df) : 0;
            ObjString *dfs = make_string(RT(vm), dflen);
            if (dflen > 0) {
                memcpy(dfs->chars, df, dflen);
            }
            return OBJ_VAL(dfs);
        }
        case NATIVE_GFX_SCREEN_W:
            return INT_VAL(ember_gfx_screen_width());
        case NATIVE_GFX_SCREEN_H:
            return INT_VAL(ember_gfx_screen_height());
        case NATIVE_GFX_SET_LAYER:
            ember_gfx_set_layer((int)AS_INT(args[0]));
            return INT_VAL(0);
        case NATIVE_GFX_CLIP_PUSH:
            ember_gfx_clip_push((int)AS_INT(args[0]), (int)AS_INT(args[1]),
                                (int)AS_INT(args[2]), (int)AS_INT(args[3]));
            return INT_VAL(0);
        case NATIVE_GFX_CLIP_POP:
            ember_gfx_clip_pop();
            return INT_VAL(0);
        case NATIVE_GFX_TAPE_OPEN:
            return INT_VAL(ember_gfx_tape_open(AS_CSTRING(args[0])));
        case NATIVE_GFX_TAPE_CLOSE:
            ember_gfx_tape_close();
            return INT_VAL(0);
        case NATIVE_GFX_TAPE_MARK:
            ember_gfx_tape_mark(AS_CSTRING(args[0]), AS_CSTRING(args[1]));
            return INT_VAL(0);
        case NATIVE_GFX_FRAME_CAPTURE:
            return INT_VAL(ember_gfx_frame_capture(AS_CSTRING(args[0])));
        case NATIVE_GFX_FILL_ROUND:
            ember_gfx_fill_round((int)AS_INT(args[0]), (int)AS_INT(args[1]), (int)AS_INT(args[2]),
                                 (int)AS_INT(args[3]), (int)AS_INT(args[4]), (int)AS_INT(args[5]),
                                 (int)AS_INT(args[6]));
            return INT_VAL(0);
        case NATIVE_GFX_STROKE_ROUND:
            ember_gfx_stroke_round((int)AS_INT(args[0]), (int)AS_INT(args[1]), (int)AS_INT(args[2]),
                                   (int)AS_INT(args[3]), (int)AS_INT(args[4]), (int)AS_INT(args[5]),
                                   (int)AS_INT(args[6]), (int)AS_INT(args[7]));
            return INT_VAL(0);
        case NATIVE_GFX_FILL_GRAD:
            ember_gfx_fill_grad((int)AS_INT(args[0]), (int)AS_INT(args[1]), (int)AS_INT(args[2]),
                                (int)AS_INT(args[3]), (int)AS_INT(args[4]), (int)AS_INT(args[5]),
                                (int)AS_INT(args[6]), (int)AS_INT(args[7]));
            return INT_VAL(0);
        case NATIVE_GFX_SHADOW:
            ember_gfx_shadow((int)AS_INT(args[0]), (int)AS_INT(args[1]), (int)AS_INT(args[2]),
                             (int)AS_INT(args[3]), (int)AS_INT(args[4]), (int)AS_INT(args[5]));
            return INT_VAL(0);
        case NATIVE_GFX_FILL_CIRCLE:
            ember_gfx_fill_circle((int)AS_INT(args[0]), (int)AS_INT(args[1]), (int)AS_INT(args[2]),
                                  (int)AS_INT(args[3]), (int)AS_INT(args[4]));
            return INT_VAL(0);
        case NATIVE_GFX_MOUSE_WHEEL:
            return INT_VAL(ember_gfx_mouse_wheel());
#endif
    }
    return INT_VAL(0);
}





#if !EMBER_MN
static VMResult run_child(VM *vm, Fiber *child, const Tracer *tracer);  // below
#endif
static VMResult run(VM *vm, Value *out, const Tracer *tracer);          // below

#if EMBER_PARALLEL && !EMBER_MN
// Parallel nursery (1:1 thread-per-fiber): each spawned fiber runs on its own OS thread, which the
// kernel schedules across all cores. A worker gets its OWN VM (private exec view + nursery
// stack) but SHARES the one Heap (allocation/free is mutex-guarded; refcounts are
// atomic). Channels block on condvars, so a worker's run() returns only when its
// fiber completes (VM_OK) or errors — never VM_YIELD. (The M:N scheduler below replaces all of
// this with a worker pool + a ready-queue of cooperatively-yielding fibers.)
typedef struct {
    Heap         *heap;
    Fiber        *fiber;
    Nursery      *nursery;
    int           slot;
    const Tracer *tracer;
    VMResult      result;
} WorkerArg;

// Per-nursery run state for the spawn-at-spawn-time model: one OS thread per task, started when the
// task is spawned and joined at the closing brace. Heap-allocated at the open (so it outlives the
// nursery body, which the parent runs concurrently) and freed at the join. `grp` is the shared
// deadlock-detector block; `args[i]` is read by worker i for its whole life, so it must persist here.
typedef struct NurseryRun {
    Nursery   grp;
    pthread_t threads[MAX_GROUP_FIBERS];
    WorkerArg args[MAX_GROUP_FIBERS];
    int       joinable[MAX_GROUP_FIBERS];   // 1 = its OS thread must be pthread_join'd
} NurseryRun;

static void *worker_entry(void *p) {
    WorkerArg *a = (WorkerArg *)p;
    VM *w = malloc(sizeof(VM));        // 1 VM per worker; the Heap is shared
    if (w == NULL) {
        a->result = VM_RUNTIME_ERROR;
        return NULL;
    }
    w->heap         = a->heap;
    w->rt.objects      = NULL;            // this worker's private, lock-free arena
    for (int c = 0; c < POOL_CLASSES; c++) {
        w->rt.pool[c] = NULL;
    }
    w->rt.structs      = a->heap->prog->structs;   // shared, read-only layout table
    w->rt.struct_count = a->heap->prog->struct_count;
    w->rt.invoke       = NULL;   // OFI-122: VM resource-drop invoke wired in a follow-up step
    w->current      = a->fiber;
    w->stack        = a->fiber->stack;
    w->frames       = a->fiber->frames;
    w->sp           = a->fiber->sp;
    w->frame_count  = a->fiber->frame_count;
    w->group_depth  = 0;               // fresh nursery context for nested spawns
    w->nursery      = a->nursery;      // the group this task is deadlock-tracked in
    w->nursery_slot = a->slot;
    Value throwaway = INT_VAL(0);      // a spawned task's return value is discarded
    a->result = run(w, &throwaway, a->tracer);

    // Hand this worker's surviving objects + recycled blocks to the shared heap so
    // the exit sweep frees them. One lock acquisition per worker, not per object.
    HEAP_LOCK(a->heap);
    if (w->rt.objects != NULL) {
        Obj *tail = w->rt.objects;
        while (tail->next != NULL) {
            tail = tail->next;
        }
        tail->next = a->heap->graveyard;
        if (a->heap->graveyard != NULL) {
            a->heap->graveyard->prev = tail;
        }
        a->heap->graveyard = w->rt.objects;
    }
    for (int c = 0; c < POOL_CLASSES; c++) {
        Obj *p = w->rt.pool[c];
        if (p != NULL) {
            Obj *tail = p;
            while (tail->next != NULL) {
                tail = tail->next;
            }
            tail->next = a->heap->gpool[c];
            a->heap->gpool[c] = p;
        }
    }
    HEAP_UNLOCK(a->heap);
    free(w);
    return NULL;
}

// A task is about to block on `ch` (is_send=1 for a send-on-full, 0 for a
// recv-on-empty): register that in its nursery slot. If every task in the group is
// now parked AND none of them could currently proceed, the group is deadlocked —
// set the flag and broadcast every channel so the sleepers wake and error out. The
// "could proceed" test is what avoids a false positive: a task signalled but not
// yet woken still shows as parked, but its channel condition is already satisfiable,
// so we do not fire. No-op at top level. Called holding `ch`'s lock; it then takes
// the nursery lock (and broadcasts the parked channels' condvars while holding it)
// — order channel→nursery, the only nesting, so there is no lock-order inversion.
static void nursery_park(VM *vm, ObjChannel *ch, int is_send) {
    Nursery *n = vm->nursery;
    if (n == NULL) {
        return;
    }
    int slot = vm->nursery_slot;
    pthread_mutex_lock(&n->lock);
    n->waits_on[slot] = ch;
    n->is_send[slot]  = is_send;
    if (!n->active[slot]) {
        n->active[slot] = 1;
        n->nwaiting++;
    }
    // Only declare a deadlock once the nursery is SEALED. Before the seal, the parent
    // is still running the body alongside the workers (spawn-at-spawn-time) and can yet
    // unblock a parked task — so an all-parked snapshot mid-body is not a deadlock. The
    // seal-time re-check in OP_NURSERY_END catches a group that parked before the seal.
    if (n->sealed && n->nwaiting == n->total) {
        int any_ready = 0;
        for (int i = 0; i < n->total && !any_ready; i++) {
            if (!n->active[i]) {
                continue;
            }
            ObjChannel *c = n->waits_on[i];
            any_ready = n->is_send[i] ? (c->count < c->capacity)
                                      : (c->count > 0 || c->closed);
        }
        if (!any_ready) {
            __atomic_store_n(&n->deadlocked, 1, __ATOMIC_SEQ_CST);
            // Wake exactly the channels this group's tasks are parked on (recorded
            // above) — no need to scan the heap, and no heap lock taken here. Each
            // parked task waits on the condvar matching how it blocked (a sender on
            // not_full, a receiver on not_empty), so wake that one to release it.
            for (int i = 0; i < n->total; i++) {
                if (n->active[i]) {
                    if (n->is_send[i]) {
                        pthread_cond_broadcast(&n->waits_on[i]->not_full);
                    } else {
                        pthread_cond_broadcast(&n->waits_on[i]->not_empty);
                    }
                }
            }
            // Reported once here; the woken tasks return the error quietly, so the
            // diagnostic matches the serial runtime's single line.
            runtime_error("deadlock: every task in the nursery is blocked");
        }
    }
    pthread_mutex_unlock(&n->lock);
}

static void nursery_unpark(VM *vm) {
    Nursery *n = vm->nursery;
    if (n == NULL) {
        return;
    }
    pthread_mutex_lock(&n->lock);
    if (n->active[vm->nursery_slot]) {
        n->active[vm->nursery_slot] = 0;
        n->nwaiting--;
    }
    pthread_mutex_unlock(&n->lock);
}

static int nursery_deadlocked(VM *vm) {
    return vm->nursery != NULL
        && __atomic_load_n(&vm->nursery->deadlocked, __ATOMIC_SEQ_CST);
}
#endif


#if EMBER_MN
// ===========================================================================================
//  M:N green-thread scheduler (OFI-071). Many lightweight fibers multiplexed over a small pool
//  of worker OS threads. The VM bytecode interpreter is the cooperative yield point: a channel
//  op that must block sets block_channel + returns VM_YIELD (just like the serial scheduler), so
//  NO stackful/ucontext context switch is needed — the Fiber struct IS the saved coroutine. This
//  replaces the 1:1 thread-per-fiber model (above) on the SAME thread-safe heap. Design + the
//  proof of the lock order and the lost-wakeup-free park: docs/architecture.md. Gated behind
//  EMBER_MN; the 1:1 build stays the default until this clears every gate (then the default flips).
// ===========================================================================================
#include <unistd.h>   // sysconf(_SC_NPROCESSORS_ONLN)

// Fiber lifecycle states. Every move between the ready-queue, a channel waiter FIFO, and "running"
// is a CAS on `fstate`, so a fiber is enqueued EXACTLY once even when a channel wake and a cancel
// sweep race for it (both attempt PARKED->READY; the CAS picks one winner).
enum { FS_READY = 0, FS_RUNNING = 1, FS_PARKED = 2, FS_DONE = 3 };

#define MAX_WORKERS 64    // cap on the worker pool (ncpu is clamped to this)

typedef struct Scheduler {
    pthread_mutex_t lock;          // guards the ready-queue + the counters below
    pthread_cond_t  nonempty;      // idle workers sleep here; a push / shutdown wakes them
    Fiber          *head, *tail;   // intrusive MPMC ready-queue (FIFO), linked via Fiber.qnext
    Fiber          *pinned;        // worker-0-ONLY ready slot: a runnable pin_worker0 fiber (the
                                   // main/GL fiber) waits here so only worker 0 resumes it. Helper
                                   // workers never service it. Holds 0 or 1 fiber (OFI-138/089).
    int             nworkers;      // M = number of worker threads (≈ ncpu)
    int             nidle;         // workers currently in cond_wait
    long            nready;        // fibers on the ready-queue
    long            live;          // fibers that exist and are not DONE (running+queued+parked)
    int             shutdown;      // program finished, deadlocked, or fatal error → workers exit
    int             halting;       // exit() requested — a clean halt must not look like a deadlock
    int             reported;      // deadlock reported once (guarded by lock)
    VMResult        global_error;  // VM_RUNTIME_ERROR once a deadlock/fatal verdict is set
    int             exit_req;      // a fiber called exit(code) — propagate to the driver
    int64_t         exit_code;
} Scheduler;

static int mn_cas(int *p, int expect, int desired) {
    return __atomic_compare_exchange_n(p, &expect, desired, 0,
                                       __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}


// ch_park links `f` onto the channel's receiver (is_send=0) or sender (is_send=1) waiter FIFO and
// marks it PARKED — all while the caller holds ch->lock, so the mark is published before any waker
// can take the lock and find it. This atomicity (re-observe emptiness AND register, under one lock)
// is what makes the park lost-wakeup-free.
static void ch_park(ObjChannel *ch, Fiber *f, int is_send) {
    f->wait_next = NULL;
    if (is_send) {
        if (ch->send_tail) { ch->send_tail->wait_next = f; } else { ch->send_head = f; }
        ch->send_tail = f;
    } else {
        if (ch->recv_tail) { ch->recv_tail->wait_next = f; } else { ch->recv_head = f; }
        ch->recv_tail = f;
    }
    __atomic_store_n(&f->fstate, FS_PARKED, __ATOMIC_RELEASE);
}


// ch_unpark dequeues one parked waiter of the given kind (still FS_PARKED) or NULL. Caller holds
// ch->lock. The returned fiber is requeue()'d by the caller AFTER releasing ch->lock (lock order).
static Fiber *ch_unpark(ObjChannel *ch, int is_send) {
    Fiber *f;
    if (is_send) {
        f = ch->send_head;
        if (f) { ch->send_head = f->wait_next; if (!ch->send_head) { ch->send_tail = NULL; } }
    } else {
        f = ch->recv_head;
        if (f) { ch->recv_head = f->wait_next; if (!ch->recv_head) { ch->recv_tail = NULL; } }
    }
    if (f) { f->wait_next = NULL; }
    return f;
}


// rq_push links a runnable fiber at the tail and wakes one idle worker. Caller must NOT hold the
// scheduler lock. The fiber must already be in state READY (the CAS that set it is the gate).
static void rq_push(Scheduler *s, Fiber *f) {
    pthread_mutex_lock(&s->lock);
    if (f->pin_worker0) {
        // The main/GL fiber resumes ONLY on worker 0 (OFI-138/089): park it in the dedicated slot
        // (it is its sole occupant — fstate gates it to one enqueue at a time) and BROADCAST so the
        // wake reaches worker 0 even if only helpers were idle. Without the pin, a nursery-join
        // resume could land the render loop's GL teardown on a helper thread → off-context SEGV.
        s->pinned = f;
        pthread_cond_broadcast(&s->nonempty);
        pthread_mutex_unlock(&s->lock);
        return;
    }
    f->qnext = NULL;
    if (s->tail) {
        s->tail->qnext = f;
    } else {
        s->head = f;
    }
    s->tail = f;
    s->nready++;
    pthread_cond_signal(&s->nonempty);
    pthread_mutex_unlock(&s->lock);
}


// requeue moves a PARKED fiber back to the ready-queue, winning the single CAS so a concurrent
// waker/cancel can't double-enqueue it. Returns 1 if this caller is the one that re-queued it.
static int requeue(Scheduler *s, Fiber *f) {
    if (!mn_cas(&f->fstate, FS_PARKED, FS_READY)) {
        return 0;   // someone else already woke it
    }
    rq_push(s, f);
    return 1;
}


// rq_pop returns the next runnable fiber, sleeping while the queue is empty. Returns NULL only on
// shutdown. The idle path is also where GLOBAL DEADLOCK is detected: if every worker is idle, the
// queue is empty, and at least one fiber still exists (parked on a channel or a nursery with no one
// left to wake it), the program is stuck. A worker is "idle" only once it is blocked here having
// found the queue empty AND its last fiber's run() has fully returned (so any park it did is already
// registered) — therefore n_idle==nworkers with an empty queue is a true, race-free global stall.
static Fiber *rq_pop(Scheduler *s, int is_worker0) {
    pthread_mutex_lock(&s->lock);
    for (;;) {
        // Worker 0 owns the pinned slot (the main/GL fiber): claim it before the shared queue and
        // before idling, so a parked-then-resumed main always runs on the calling/GL thread. Helper
        // workers skip this — they must never run a pinned fiber (OFI-138/089).
        if (is_worker0 && s->pinned != NULL) {
            Fiber *f = s->pinned;
            s->pinned = NULL;
            pthread_mutex_unlock(&s->lock);
            return f;
        }
        if (s->head != NULL) {
            Fiber *f = s->head;
            s->head = f->qnext;
            if (!s->head) {
                s->tail = NULL;
            }
            s->nready--;
            pthread_mutex_unlock(&s->lock);
            return f;
        }
        if (s->shutdown) {              // shut down (here or elsewhere) → do NOT wait, exit
            pthread_mutex_unlock(&s->lock);
            return NULL;
        }
        s->nidle++;
        if (s->nidle == s->nworkers && s->nready == 0 && s->pinned == NULL && s->live >= 1
                && !s->halting && !s->reported) {
            // Every worker is idle, nothing is runnable (the shared queue AND the worker-0 pinned
            // slot are empty), yet fibers remain (all parked on channels / nurseries with no one
            // left to wake them): a true global deadlock. Report once + shut down.
            s->reported = 1;
            s->global_error = VM_RUNTIME_ERROR;
            s->shutdown = 1;
            runtime_error("deadlock: every task in the nursery is blocked");
            pthread_cond_broadcast(&s->nonempty);
        }
        if (s->shutdown) {
            s->nidle--;
            pthread_mutex_unlock(&s->lock);
            return NULL;
        }
        pthread_cond_wait(&s->nonempty, &s->lock);
        s->nidle--;
    }
}


// retire_fiber reclaims a finished fiber's private arena and frees it. The fiber is DONE and only
// this worker touches it. Its recycle POOL holds dead blocks (free them outright — bounds RSS for
// spawn-heavy programs); its live `objects` list (empty after a clean run — its locals were dropped
// during run(); a cross-home value received via a channel is the OFI-018 residual) is spliced into
// the shared graveyard for the exit sweep, since another fiber may still hold such an object.
static void retire_fiber(VM *w, Fiber *f) {
    drain_pool(f->rt.pool);                 // free the recycled dead blocks (safe: owned, unreferenced)
    if (f->rt.objects != NULL) {
        HEAP_LOCK(w->heap);
        Obj *tail = f->rt.objects;
        while (tail->next != NULL) {
            tail = tail->next;
        }
        tail->next = w->heap->graveyard;
        if (w->heap->graveyard != NULL) {
            w->heap->graveyard->prev = tail;
        }
        w->heap->graveyard = f->rt.objects;
        HEAP_UNLOCK(w->heap);
    }
    free(f);
}


// finish_child handles a fiber that has left run() for good (VM_OK / error / cancelled). It marks the
// fiber DONE, accounts it against its nursery (waking a parked parent when it was the last child) and
// the global `live` count (triggering shutdown when the last fiber finishes), then retires it.
static void finish_child(VM *w, Fiber *f, VMResult r) {
    Scheduler *s = w->sched;
    __atomic_store_n(&f->fstate, FS_DONE, __ATOMIC_RELEASE);
    Nursery *n = f->nursery;
    if (n != NULL) {
        // On an error (or a propagated cancel), the first one sets the verdict + cancels siblings:
        // structured concurrency (founding principle #4) — a failing task tears the group down.
        if (r == VM_RUNTIME_ERROR || r == VM_CANCELLED) {
            int already = __atomic_exchange_n(&n->cancel, 1, __ATOMIC_SEQ_CST);
            if (r == VM_RUNTIME_ERROR) {
                pthread_mutex_lock(&n->lock);
                if (n->verdict == (int)VM_OK) {
                    n->verdict = (int)VM_RUNTIME_ERROR;
                }
                pthread_mutex_unlock(&n->lock);
            }
            if (!already) {
                // Wake every sibling so it observes `cancel` at its next yield seam and unwinds.
                // Safe to walk the child list + requeue: children are freed only at the parent's
                // finalize (after live==0), so none here is freed; requeue is a no-op on a running
                // or already-DONE sibling (its PARKED->READY CAS fails).
                pthread_mutex_lock(&n->lock);
                for (Fiber *sib = n->children; sib != NULL; sib = sib->sib_next) {
                    if (sib != f) {
                        requeue(s, sib);
                    }
                }
                pthread_mutex_unlock(&n->lock);
            }
        }
        // Last child wakes the parked parent. live-- AND the parent's seal-time live read are BOTH
        // under n->lock, so exactly one of {parent parks then is woken here} / {parent sees live==0
        // and finalizes} happens — no lost wakeup. The PARENT always frees the nursery + its children
        // (never a child frees itself), so the cancel sweep above can't race a child free.
        pthread_mutex_lock(&n->lock);
        n->live--;
        Fiber *parent = (n->live == 0 && n->parent_parked) ? n->parent : NULL;
        if (parent != NULL) {
            n->parent_parked = 0;
        }
        pthread_mutex_unlock(&n->lock);
        if (parent != NULL) {
            requeue(s, parent);
        }
    } else {
        // A top-level fiber (main) has no parent to free it at a join — retire it here.
        retire_fiber(w, f);
    }
    // Global liveness: when the last fiber (incl. main) finishes, the program is done. A top-level
    // fiber (main) that errors has no parent to carry its verdict, so record it as the global error
    // here; vm_run returns it as the program's result (matching the serial exit code).
    pthread_mutex_lock(&s->lock);
    if (n == NULL && r == VM_RUNTIME_ERROR && s->global_error == VM_OK) {
        s->global_error = VM_RUNTIME_ERROR;
    }
    s->live--;
    if (s->live == 0) {
        s->shutdown = 1;
        pthread_cond_broadcast(&s->nonempty);
    }
    pthread_mutex_unlock(&s->lock);
}


// run_fiber_once points the worker's exec view (and arena) at `f`, runs the interpreter until the
// fiber yields/finishes, then saves the fiber's progress. The worker has no fiber of its own, so
// there is nothing to restore afterward — the next pop repoints the view again.
static VMResult run_fiber_once(VM *w, Fiber *f, const Tracer *tracer) {
    w->current     = f;
    w->stack       = f->stack;
    w->frames      = f->frames;
    w->sp          = f->sp;
    w->frame_count = f->frame_count;
    w->active_rt   = &f->rt;
    Value throwaway = INT_VAL(0);
    VMResult r = run(w, f->out ? f->out : &throwaway, tracer);
    f->sp          = w->sp;          // save progress so a later resume continues here
    f->frame_count = w->frame_count;
    return r;
}


// scheduler_worker_main is the loop every worker thread runs (worker 0 = the calling thread). Pop a
// runnable fiber, win it (READY->RUNNING), run it: VM_YIELD means the fiber already parked + registered
// itself (on a channel or its nursery) — do nothing; VM_OK/ERROR/CANCELLED means it is finished.
static void scheduler_worker_main(VM *w, const Tracer *tracer, int is_worker0) {
    Scheduler *s = w->sched;
    for (;;) {
        Fiber *f = rq_pop(s, is_worker0);
        if (f == NULL) {
            return;   // shutdown
        }
        if (!mn_cas(&f->fstate, FS_READY, FS_RUNNING)) {
            continue; // it was already claimed/woken elsewhere; skip
        }
        VMResult r = run_fiber_once(w, f, tracer);
        if (w->exit_requested) {
            // A fiber called exit(code): halt the whole pool cleanly (this is not a deadlock). Record
            // the code for the driver, finish this fiber, then signal shutdown so every worker exits.
            pthread_mutex_lock(&s->lock);
            if (!s->exit_req) {
                s->exit_req   = 1;
                s->exit_code  = w->exit_code;
            }
            s->halting  = 1;
            s->shutdown = 1;
            pthread_cond_broadcast(&s->nonempty);
            pthread_mutex_unlock(&s->lock);
            finish_child(w, f, VM_OK);
            return;
        }
        if (r == VM_YIELD) {
            continue; // parked itself; a waker will requeue it
        }
        finish_child(w, f, r);   // VM_OK / VM_RUNTIME_ERROR / VM_CANCELLED
    }
}


// A worker thread other than worker 0. Each gets its OWN VM (private exec view) sharing the heap +
// the one scheduler; the arena travels with each fiber, so the worker VM owns no arena.
typedef struct { VM *w; const Tracer *tracer; } MNWorkerArg;

static void *mn_worker_entry(void *p) {
    MNWorkerArg *a = (MNWorkerArg *)p;
    scheduler_worker_main(a->w, a->tracer, 0);   // a helper worker — never services the pinned slot
    return NULL;
}
#endif


// emit_trace fires one trace event for the instruction `frame->ip` is about to
// execute. Factored out so the switch and computed-goto dispatchers share it.
static void emit_trace(const Tracer *tracer, const CallFrame *frame, const VM *vm) {
    const Chunk *chunk = &frame->fn->chunk;
    size_t offset = (size_t)(frame->ip - chunk->code);
    TraceEvent event;
    event.fn          = frame->fn->name;
    event.ip          = offset;
    event.op          = (OpCode)*frame->ip;
    event.line        = chunk->lines ? chunk->lines[offset] : 0;
    event.stack       = vm->stack;
    event.stack_count = (size_t)(vm->sp - vm->stack);
    event.event       = NULL;          // an ordinary per-instruction step
    event.detail      = NULL;
    tracer->on_event(tracer->ctx, &event);
}

// emit_semantic_event fires a richer, named event on the same trace seam (MANIFESTO
// §5c) — used so a contract violation reaches an LLM author as structured data, not
// just an abort. No-op when no tracer is attached.
static void emit_semantic_event(const Tracer *tracer, const CallFrame *frame,
                                const VM *vm, const char *kind, const char *detail) {
    if (tracer == NULL) {
        return;
    }
    const Chunk *chunk = &frame->fn->chunk;
    size_t offset = (size_t)(frame->ip - chunk->code);
    TraceEvent event;
    event.fn          = frame->fn->name;
    event.ip          = offset;
    event.op          = (OpCode)chunk->code[offset > 0 ? offset - 1 : 0];
    event.line        = chunk->lines ? chunk->lines[offset] : 0;
    event.stack       = vm->stack;
    event.stack_count = (size_t)(vm->sp - vm->stack);
    event.event       = kind;
    event.detail      = detail;
    tracer->on_event(tracer->ctx, &event);
}

// Dispatch is a portable `switch` by default; setting EMBER_THREADED to 1 (on
// GCC/Clang) switches it to computed-goto "threaded" dispatch, where each handler
// ends with its own indirect jump to the next instruction so the CPU sees a
// distinct, separately-predicted branch per opcode rather than one shared switch
// branch. The handler bodies are identical for both — VM_CASE labels each, VM_NEXT
// dispatches the next instruction (running the trace hook first).
//
// MEASURED 2026-06-12 (Apple Silicon / arm64, clang -O2): threading is ~11% SLOWER
// here (flex_bench 0.30s -> 0.33s; `arrays` and `enums` regress most) — the M-series
// branch predictor handles the switch's single indirect branch better than the
// table-load + indirect-jump per handler. So it is OFF. It is left as a one-line
// toggle because the trade flips by microarchitecture: on x86 server cores with
// weaker indirect prediction it has historically helped, and that is worth a
// re-measure there before enabling. Do not enable without benchmarking the target.
#if !defined(EMBER_THREADED)
#define EMBER_THREADED 0
#endif

// push_string_const interns a string-literal pool entry on first use (the chunk keeps its own
// reference so the object outlives every program copy) and pushes a counted reference; later
// executions just bump the refcount.
static int push_string_const(VM *vm, StringConst *sc) {
    ObjString *s = sc->cached;
    if (s == NULL) {
        s = make_string(RT(vm), sc->length);
        memcpy(s->chars, sc->data, sc->length);
        OBJ_RETAIN(&s->obj);   // the chunk's reference, held all run
        sc->cached = s;
    } else {
        OBJ_RETAIN(&s->obj);   // the pushed copy's reference
    }
    return push(vm, OBJ_VAL(s));
}


#if EMBER_OPCHECK
// opcheck_step verifies, after an instruction ran, that its handler consumed EXACTLY the operand
// bytes the opcode's spec declares — the proactive net for the narrow-operand class (OFI-007/047/
// 056: a one-byte field wrapping a >255 value, or a handler reading the wrong width). Compiled only
// in a -DEMBER_OPCHECK build (zero release cost) and run over the whole test corpus by `make
// opcheck`. It checks only LINEAR ops in the SAME frame: a jump/call/return/spawn legitimately
// reassigns ip or swaps frames, so its ip movement is a branch, not the operand width. `operands`
// is the ip just after the opcode byte; `frame` is the frame as it stands AFTER the handler ran.
static void opcheck_step(VM *vm, CallFrame *frame, OpCode op, const uint8_t *operands,
                         CallFrame *prev_frame, int prev_fc) {
    if (vm->frame_count != prev_fc || frame != prev_frame) {
        return;
    }
    switch (op) {
        case OP_JUMP: case OP_JUMP_IF_FALSE: case OP_LOOP:
        case OP_FOR_RANGE: case OP_FOR_ARRAY:
        case OP_SPAWN: case OP_NURSERY_BEGIN: case OP_NURSERY_END:
            return;
        default:
            break;
    }
    int width = opcode_operand_bytes_at(op, operands);
    ptrdiff_t consumed = frame->ip - operands;
    if (consumed != width) {
        fprintf(stderr, "\n*** OPCHECK: %s consumed %td operand byte(s), spec declares %d ***\n",
                opcode_name(op), consumed, width);
        abort();
    }
}
#endif


// run is the interpreter loop. It may return at any point; vm_run owns the VM
// and frees its objects afterward, so cleanup is not duplicated here.
static VMResult run(VM *vm, Value *out, const Tracer *tracer) {
    CallFrame *frame = &vm->frames[vm->frame_count - 1];
    OpCode op;

#if EMBER_THREADED
    // One label per opcode, in enum order, generated from the opcode list so the
    // table can never drift from the handlers (a missing handler is a missing
    // label is a compile error). OP__COUNT catches a corrupt opcode byte.
    static const void *const dispatch_table[] = {
#define X(name, mnemonic, operands) [name] = &&L_##name,
        EMBER_OPCODES(X)
#undef X
        [OP__COUNT] = &&L_OP__COUNT,
    };
#define VM_CASE(o) L_##o
#define VM_NEXT()                                                       \
    do {                                                                \
        if (tracer != NULL) { emit_trace(tracer, frame, vm); }          \
        op = (OpCode)*frame->ip++;                                      \
        goto *dispatch_table[op];                                       \
    } while (0)
    VM_NEXT();   // jump to the first instruction
#else
#define VM_CASE(o) case o
#define VM_NEXT() break
#if EMBER_OPCHECK
    OpCode         oc_prev_op       = OP__COUNT;   // OP__COUNT = "no previous instruction yet"
    const uint8_t *oc_prev_operands = NULL;
    CallFrame     *oc_prev_frame    = NULL;
    int            oc_prev_fc       = 0;
#endif
    for (;;) {
#if EMBER_OPCHECK
        if (oc_prev_op != OP__COUNT) {
            opcheck_step(vm, frame, oc_prev_op, oc_prev_operands, oc_prev_frame, oc_prev_fc);
        }
#endif
        if (tracer != NULL) { emit_trace(tracer, frame, vm); }
        op = (OpCode)*frame->ip++;
#if EMBER_OPCHECK
        oc_prev_op       = op;
        oc_prev_operands = frame->ip;     // ip now points at this instruction's operands
        oc_prev_frame    = frame;
        oc_prev_fc       = vm->frame_count;
#endif
        switch (op) {
#endif
            VM_CASE(OP_CONST): {
                size_t index = operand_read(&frame->ip, OPK_IDX);   // unbounded LEB128 pool index
                if (!push(vm, frame->fn->chunk.consts[index])) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_STRING): {
                // A literal interns on first execution; later executions are a refcount bump.
                // Sound because strings are immutable and `==` compares contents.
                size_t index = operand_read(&frame->ip, OPK_IDX);
                if (!push_string_const(vm, &frame->fn->chunk.strings[index])) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_TRUE):
                if (!push(vm, INT_VAL(1))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            VM_CASE(OP_FALSE):
                if (!push(vm, INT_VAL(0))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            VM_CASE(OP_POP):
                pop(vm);
                VM_NEXT();
            VM_CASE(OP_DUP):
                // Push a copy of the top value — `?` tests an enum's tag while
                // keeping the value to extract from or return.
                if (!push(vm, vm->sp[-1])) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            VM_CASE(OP_GET_LOCAL): {
                size_t slot = operand_read(&frame->ip, OPK_IDX);
                if (!push(vm, frame->slots[slot])) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_SET_LOCAL): {
                size_t slot = operand_read(&frame->ip, OPK_IDX);
                frame->slots[slot] = vm->sp[-1];   // assignment yields its value
                VM_NEXT();
            }
            VM_CASE(OP_ADD): {
                // `+` concatenates two strings, otherwise it is numeric add. The
                // numeric-kind byte gives the int result's width (ignored for
                // strings/floats).
                uint8_t nk = *frame->ip++;
                Value b = pop(vm);
                Value a = pop(vm);
                if (IS_INT(a) && nk == 0) {
                    // The common case — plain i64 — tested first, before the
                    // string/float tag checks and the width-bounds table.
                    int64_t r;
                    if (__builtin_add_overflow(AS_INT(a), AS_INT(b), &r)) {
                        overflow_fault(vm, frame, AS_INT(a), AS_INT(b), nk == 7);
                        return VM_RUNTIME_ERROR;
                    }
                    if (!push(vm, INT_VAL(r))) {
                        return VM_RUNTIME_ERROR;
                    }
                } else if (IS_STRING(a) && IS_STRING(b)) {
                    ObjString *sa = AS_STRING(a);
                    ObjString *sb = AS_STRING(b);
                    ObjString *r = make_string(RT(vm), sa->length + sb->length);
                    memcpy(r->chars, sa->chars, sa->length);
                    memcpy(r->chars + sa->length, sb->chars, sb->length);
                    if (!push(vm, OBJ_VAL(r))) {
                        return VM_RUNTIME_ERROR;
                    }
                } else if (IS_FLOAT(a)) {
                    double fr = AS_FLOAT(a) + AS_FLOAT(b);
                    if (nk == 8) { fr = (float)fr; }   // f32 rounding
                    if (!push(vm, FLOAT_VAL(fr))) {
                        return VM_RUNTIME_ERROR;
                    }
                } else if (nk == 7) {                  // u64 unsigned add
                    uint64_t ur;
                    if (__builtin_add_overflow((uint64_t)AS_INT(a),
                                               (uint64_t)AS_INT(b), &ur)) {
                        overflow_fault(vm, frame, AS_INT(a), AS_INT(b), nk == 7);
                        return VM_RUNTIME_ERROR;
                    }
                    if (!push(vm, INT_VAL((int64_t)ur))) {
                        return VM_RUNTIME_ERROR;
                    }
                } else {
                    int64_t r;
                    if (__builtin_add_overflow(AS_INT(a), AS_INT(b), &r) ||
                        r < NK_MIN[nk] || r > NK_MAX[nk]) {
                        overflow_fault(vm, frame, AS_INT(a), AS_INT(b), nk == 7);
                        return VM_RUNTIME_ERROR;
                    }
                    if (!push(vm, INT_VAL(r))) {
                        return VM_RUNTIME_ERROR;
                    }
                }
                VM_NEXT();
            }
            VM_CASE(OP_CONCAT): {
                // String concatenation that CONSUMES (releases) both operands. Emitted only by the
                // interpolation fold (OFI-059), where every operand is an OWNED reference — an
                // interned-literal push (OP_STRING retains), an owned OP_TO_STRING result, or a
                // prior OP_CONCAT result — so releasing them frees the intermediate temporaries
                // instead of leaking them. (General `+` keeps the NON-consuming OP_ADD, whose
                // operands may be borrowed locals that must not be freed.)
                Value b = pop(vm);
                Value a = pop(vm);
                ObjString *sa = AS_STRING(a);
                ObjString *sb = AS_STRING(b);
                ObjString *r = make_string(RT(vm), sa->length + sb->length);
                memcpy(r->chars, sa->chars, sa->length);
                memcpy(r->chars + sa->length, sb->chars, sb->length);
                drop_value(RT(vm), a);     // release the two consumed operands (intermediates freed)
                drop_value(RT(vm), b);
                if (!push(vm, OBJ_VAL(r))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_SUB): ARITH(__builtin_sub_overflow, -); VM_NEXT();
            VM_CASE(OP_MUL): ARITH(__builtin_mul_overflow, *); VM_NEXT();
            VM_CASE(OP_WRAP_ADD): WRAP(+); VM_NEXT();
            VM_CASE(OP_WRAP_SUB): WRAP(-); VM_NEXT();
            VM_CASE(OP_WRAP_MUL): WRAP(*); VM_NEXT();
            VM_CASE(OP_DIV): {
                uint8_t nk = *frame->ip++;
                Value vb = pop(vm);
                Value va = pop(vm);
                if (IS_FLOAT(va)) {
                    double fr = AS_FLOAT(va) / AS_FLOAT(vb);
                    if (nk == 8) { fr = (float)fr; }
                    if (!push(vm, FLOAT_VAL(fr))) {
                        return VM_RUNTIME_ERROR;
                    }
                } else if (nk == 7) {                  // u64 unsigned divide
                    uint64_t a = (uint64_t)AS_INT(va), b = (uint64_t)AS_INT(vb);
                    if (b == 0) {
                        // The dividend is a genuine u64 — render it unsigned, not its i64 view (OFI-110/111c).
                        FaultInt vals[2] = { { "divisor", (int64_t)b, 1 }, { "dividend", (int64_t)a, 1 } };
                        runtime_fault(vm, frame, "division_by_zero", "division by zero",
                                      "division requires a non-zero divisor",
                                      "guard the divisor with `if d != 0`, or return a Result for the zero case",
                                      vals, 2);
                        return VM_RUNTIME_ERROR;
                    }
                    if (!push(vm, INT_VAL((int64_t)(a / b)))) {
                        return VM_RUNTIME_ERROR;
                    }
                } else {
                    int64_t a = AS_INT(va), b = AS_INT(vb);
                    if (b == 0) {
                        FaultInt vals[2] = { { "divisor", b, 0 }, { "dividend", a, 0 } };
                        runtime_fault(vm, frame, "division_by_zero", "division by zero",
                                      "division requires a non-zero divisor",
                                      "guard the divisor with `if d != 0`, or return a Result for the zero case",
                                      vals, 2);
                        return VM_RUNTIME_ERROR;
                    }
                    // a/b can still leave the width (e.g. i8 -128 / -1 = 128).
                    if ((a == INT64_MIN && b == -1) ||
                        a / b < NK_MIN[nk] || a / b > NK_MAX[nk]) {
                        overflow_fault(vm, frame, a, b, nk == 7);
                        return VM_RUNTIME_ERROR;
                    }
                    if (!push(vm, INT_VAL(a / b))) {
                        return VM_RUNTIME_ERROR;
                    }
                }
                VM_NEXT();
            }
            VM_CASE(OP_MOD): {
                uint8_t nk = *frame->ip++;   // a remainder always fits the width
                int64_t b = AS_INT(pop(vm));
                int64_t a = AS_INT(pop(vm));
                if (b == 0) {
                    // A u64 dividend renders unsigned (OFI-110/111c); 0/other widths stay signed.
                    FaultInt vals[2] = { { "divisor", b, nk == 7 }, { "dividend", a, nk == 7 } };
                    runtime_fault(vm, frame, "modulo_by_zero", "modulo by zero",
                                  "modulo requires a non-zero divisor",
                                  "guard the divisor with `if d != 0` before `%`",
                                  vals, 2);
                    return VM_RUNTIME_ERROR;
                }
                int64_t r;
                if (nk == 7) {                          // u64 unsigned remainder
                    r = (int64_t)((uint64_t)a % (uint64_t)b);
                } else {
                    // INT64_MIN % -1 is 0 mathematically but UB in C; give the
                    // defined result directly.
                    r = (a == INT64_MIN && b == -1) ? 0 : a % b;
                }
                if (!push(vm, INT_VAL(r))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_NEG): {
                uint8_t nk = *frame->ip++;
                Value va = pop(vm);
                if (IS_FLOAT(va)) {
                    double fr = -AS_FLOAT(va);
                    if (nk == 8) { fr = (float)fr; }
                    if (!push(vm, FLOAT_VAL(fr))) {
                        return VM_RUNTIME_ERROR;
                    }
                } else if (nk == 7) {                  // -u64 is valid only for 0
                    if (AS_INT(va) != 0) {
                        overflow_fault1(vm, frame, AS_INT(va), nk == 7);
                        return VM_RUNTIME_ERROR;
                    }
                    if (!push(vm, INT_VAL(0))) {
                        return VM_RUNTIME_ERROR;
                    }
                } else {
                    int64_t a = AS_INT(va);
                    // Negation can leave the width: -INT64_MIN, -(i8 -128) = 128,
                    // or any non-zero unsigned (the result would be negative).
                    if (a == INT64_MIN || -a < NK_MIN[nk] || -a > NK_MAX[nk]) {
                        overflow_fault1(vm, frame, a, nk == 7);
                        return VM_RUNTIME_ERROR;
                    }
                    if (!push(vm, INT_VAL(-a))) {
                        return VM_RUNTIME_ERROR;
                    }
                }
                VM_NEXT();
            }
            VM_CASE(OP_NOT): {
                int64_t a = AS_INT(pop(vm));   // bool is an int 0/1
                if (!push(vm, INT_VAL(a == 0 ? 1 : 0))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            // Bitwise and/or/xor are width-transparent: the bit pattern of two
            // in-width values (signed values stored sign-extended, unsigned zero-
            // extended) combines to a value that is still in width, so no kind byte
            // and no fixup are needed.
            VM_CASE(OP_BITAND): {
                int64_t b = AS_INT(pop(vm));
                int64_t a = AS_INT(pop(vm));
                if (!push(vm, INT_VAL(a & b))) { return VM_RUNTIME_ERROR; }
                VM_NEXT();
            }
            VM_CASE(OP_BITOR): {
                int64_t b = AS_INT(pop(vm));
                int64_t a = AS_INT(pop(vm));
                if (!push(vm, INT_VAL(a | b))) { return VM_RUNTIME_ERROR; }
                VM_NEXT();
            }
            VM_CASE(OP_BITXOR): {
                int64_t b = AS_INT(pop(vm));
                int64_t a = AS_INT(pop(vm));
                if (!push(vm, INT_VAL(a ^ b))) { return VM_RUNTIME_ERROR; }
                VM_NEXT();
            }
            VM_CASE(OP_BITNOT): {
                uint8_t nk = *frame->ip++;
                int64_t a  = AS_INT(pop(vm));
                int64_t r;
                if (nk >= 4 && nk <= 6) {
                    // Narrow unsigned: ~a would set the high bits, so mask to width.
                    r = (int64_t)((~(uint64_t)a) & (uint64_t)NK_MAX[nk]);
                } else {
                    // Signed (stays correctly sign-extended) and u64 (full complement).
                    r = ~a;
                }
                if (!push(vm, INT_VAL(r))) { return VM_RUNTIME_ERROR; }
                VM_NEXT();
            }
            // Shifts are bit operations: the value is truncated to its width
            // (wrapping), and the shift amount must be in [0, width) or it traps.
            // '<<' is logical; '>>' is arithmetic for signed kinds, logical for
            // unsigned. The operand byte is the LEFT operand's numeric kind.
            VM_CASE(OP_SHL): {
                uint8_t nk = *frame->ip++;
                int64_t nb = AS_INT(pop(vm));
                int64_t a  = AS_INT(pop(vm));
                int bits = nk_bits(nk);
                if (nb < 0 || nb >= bits) {
                    FaultInt vals[2] = { { "shift", nb, 0 }, { "width", (int64_t)bits, 0 } };
                    runtime_fault(vm, frame, "shift_out_of_range", "shift amount out of range",
                                  "shifting requires 0 <= amount < width",
                                  "the shift amount must be in [0, width); mask it or check the range first",
                                  vals, 2);
                    return VM_RUNTIME_ERROR;
                }
                uint64_t mask = (bits == 64) ? ~0ull : (((uint64_t)1 << bits) - 1);
                uint64_t ur = ((uint64_t)a << nb) & mask;
                if (nk <= 3 && bits < 64 && ((ur >> (bits - 1)) & 1)) {
                    ur |= ~mask;            // re-sign-extend a narrow signed result
                }
                if (!push(vm, INT_VAL((int64_t)ur))) { return VM_RUNTIME_ERROR; }
                VM_NEXT();
            }
            VM_CASE(OP_SHR): {
                uint8_t nk = *frame->ip++;
                int64_t nb = AS_INT(pop(vm));
                int64_t a  = AS_INT(pop(vm));
                int bits = nk_bits(nk);
                if (nb < 0 || nb >= bits) {
                    FaultInt vals[2] = { { "shift", nb, 0 }, { "width", (int64_t)bits, 0 } };
                    runtime_fault(vm, frame, "shift_out_of_range", "shift amount out of range",
                                  "shifting requires 0 <= amount < width",
                                  "the shift amount must be in [0, width); mask it or check the range first",
                                  vals, 2);
                    return VM_RUNTIME_ERROR;
                }
                int64_t r;
                if (nk <= 3) {
                    r = a >> nb;            // arithmetic (signed); narrow stays in width
                } else {
                    uint64_t mask = (bits == 64) ? ~0ull : (((uint64_t)1 << bits) - 1);
                    r = (int64_t)(((uint64_t)a & mask) >> nb);   // logical (unsigned)
                }
                if (!push(vm, INT_VAL(r))) { return VM_RUNTIME_ERROR; }
                VM_NEXT();
            }
            VM_CASE(OP_EQ):
            VM_CASE(OP_NEQ): {
                Value b = pop(vm);
                Value a = pop(vm);
                int eq;
                if (IS_STRING(a) && IS_STRING(b)) {
                    ObjString *sa = AS_STRING(a);
                    ObjString *sb = AS_STRING(b);
                    eq = sa->length == sb->length &&
                         memcmp(sa->chars, sb->chars, sa->length) == 0;
                } else if (IS_FLOAT(a)) {
                    eq = (AS_FLOAT(a) == AS_FLOAT(b));
                } else {
                    eq = (AS_INT(a) == AS_INT(b));
                }
                if (op == OP_NEQ) {
                    eq = !eq;
                }
                if (!push(vm, INT_VAL(eq ? 1 : 0))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_LT):  COMPARE(<);  VM_NEXT();
            VM_CASE(OP_LE):  COMPARE(<=); VM_NEXT();
            VM_CASE(OP_GT):  COMPARE(>);  VM_NEXT();
            VM_CASE(OP_GE):  COMPARE(>=); VM_NEXT();
            VM_CASE(OP_JUMP): {
                uint16_t offset = (uint16_t)((frame->ip[0] << 8) | frame->ip[1]);
                frame->ip += 2;
                frame->ip += offset;
                VM_NEXT();
            }
            VM_CASE(OP_JUMP_IF_FALSE): {
                uint16_t offset = (uint16_t)((frame->ip[0] << 8) | frame->ip[1]);
                frame->ip += 2;
                if (AS_INT(vm->sp[-1]) == 0) {
                    frame->ip += offset;
                }
                VM_NEXT();
            }
            VM_CASE(OP_CONTRACT_CHECK): {
                // A contract predicate (bool) is on the stack; if it is false, the
                // contract was violated — abort with the codegen-built message. The
                // message index points into this function's string pool.
                size_t msg_index = operand_read(&frame->ip, OPK_IDX);
                int holds = (AS_INT(vm->sp[-1]) != 0);
                vm->sp--;                              // pop the predicate
                if (!holds) {
                    const char *msg = frame->fn->chunk.strings[msg_index].data;
                    if (vm->check_mode) {
                        // Property-checking (§5j): record + unwind, don't abort. The fuzzer
                        // classifies by message (a `requires` failure means the generated input
                        // is out of domain; anything else is a real counterexample).
                        vm->check_msg = msg;
                        return VM_RUNTIME_ERROR;
                    }
                    // Report on the trace seam first (structured, for an LLM author),
                    // then as the runtime error that aborts the run.
                    emit_semantic_event(tracer, frame, vm, "contract_violation", msg);
                    contract_fault(vm, frame, msg);
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_LOOP): {
                uint16_t offset = (uint16_t)((frame->ip[0] << 8) | frame->ip[1]);
                frame->ip += 2;
                frame->ip -= offset;
#if EMBER_MN
                // Cancellation seam (founding principle #4): a fiber whose nursery was cancelled
                // (a sibling errored) unwinds at the loop back-edge, so even a tight compute loop is
                // cancellable. One relaxed-ish atomic load per back-edge; only on the M:N build.
                {
                    Nursery *cn = vm->current->nursery;
                    if (cn != NULL && __atomic_load_n(&cn->cancel, __ATOMIC_ACQUIRE)) {
                        return VM_CANCELLED;
                    }
                }
#endif
                VM_NEXT();
            }
            VM_CASE(OP_FOR_RANGE): {
                // Fused counted-loop step: pre-increment the index (initialised to
                // lo-1), and exit when it reaches the exclusive bound. One opcode
                // replaces the manual increment + compare + branch. The index can't
                // overflow: it only ever reaches `end` (<= INT64_MAX), then exits.
                size_t i_slot    = operand_read(&frame->ip, OPK_IDX);
                size_t end_slot  = operand_read(&frame->ip, OPK_IDX);
                uint16_t exit_off = (uint16_t)((frame->ip[0] << 8) | frame->ip[1]);
                frame->ip += 2;
                int64_t i = AS_INT(frame->slots[i_slot]) + 1;
                frame->slots[i_slot] = INT_VAL(i);
                if (i >= AS_INT(frame->slots[end_slot])) {
                    frame->ip += exit_off;
                }
                VM_NEXT();
            }
            VM_CASE(OP_FOR_ARRAY): {
                // Fused array-iteration step: pre-increment the index, exit at the
                // cached length, else bind the loop variable to the next element
                // (a borrow — the array owns it). The length is read once before
                // the loop, so it is not recomputed each iteration.
                size_t arr_slot  = operand_read(&frame->ip, OPK_IDX);
                size_t idx_slot  = operand_read(&frame->ip, OPK_IDX);
                size_t len_slot  = operand_read(&frame->ip, OPK_IDX);
                size_t var_slot  = operand_read(&frame->ip, OPK_IDX);
                uint16_t exit_off = (uint16_t)((frame->ip[0] << 8) | frame->ip[1]);
                frame->ip += 2;
                int64_t idx = AS_INT(frame->slots[idx_slot]) + 1;
                frame->slots[idx_slot] = INT_VAL(idx);
                if (idx >= AS_INT(frame->slots[len_slot])) {
                    frame->ip += exit_off;
                } else {
                    ObjArray *a = AS_ARRAY(frame->slots[arr_slot]);
                    frame->slots[var_slot] = array_box(a, (size_t)idx);
                }
                VM_NEXT();
            }
            VM_CASE(OP_NEW_STRUCT): {
                int type_id     = (int)operand_read(&frame->ip, OPK_IDX);
                int field_count = (int)operand_read(&frame->ip, OPK_IDX);
                Value instance = alloc_instance(RT(vm), type_id, 0, 0, field_count);
                // Fields were pushed in declared order; pop fills back-to-front,
                // unboxing each into its packed slot.
                for (int i = field_count - 1; i >= 0; i--) {
                    int k;
                    unsigned char *p = field_loc(RT(vm), AS_STRUCT(instance), i, &k);
                    Value fv = pop(vm);
                    if (k == AEK_INLINE_STRUCT) {
                        // The field value is a constructed nested struct: copy its bytes into
                        // the parent's inline slot and reclaim the source shell (value-types
                        // 3b.5; the bytes move in, an all-scalar struct shares nothing).
                        int nsid = field_inline_sid(RT(vm), AS_STRUCT(instance), i);
                        memcpy(p, AS_STRUCT(fv)->data,
                               (size_t)vm->heap->prog->structs[nsid].total_size);
                        reclaim(RT(vm), AS_OBJ(fv));
                    } else {
                        value_unbox(p, k, fv);
                    }
                }
                if (!push(vm, instance)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_UNBOX_STRUCT): {
                // Explode a boxed struct into its fields as individual stack Values
                // (declared order) — the multi-slot value-types representation (3b). The
                // pushed values ADOPT the struct's references (value_box doesn't incref),
                // so the shell is freed WITHOUT releasing fields: ownership transfers.
                int sid = (int)operand_read(&frame->ip, OPK_IDX);
                Value boxed = pop(vm);
                ObjStruct *s = AS_STRUCT(boxed);
                // Flatten the packed buffer into one stack slot per LEAF scalar, recursing
                // through inline nested struct fields (value-types 3b.5-B).
                if (!unbox_flatten(vm, sid, s->data)) {
                    return VM_RUNTIME_ERROR;
                }
                reclaim(RT(vm), (Obj *)s);
                VM_NEXT();
            }
            VM_CASE(OP_UNBOX_STRUCT_BORROW): {
                // Explode a BORROWED boxed struct (a named local passed by value to a multi-slot
                // param) into its leaf slots. Unlike OP_UNBOX_STRUCT this RETAINS each heap leaf
                // (the source local keeps ownership; the callee's param releases its copy) and does
                // NOT reclaim the shell — so the live local isn't freed (OFI-058).
                int sid = (int)operand_read(&frame->ip, OPK_IDX);
                Value boxed = pop(vm);
                ObjStruct *s = AS_STRUCT(boxed);
                if (!unbox_flatten_borrow(vm, sid, s->data)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_BOX_STRUCT): {
                // Implode N field values (on the stack, declared order, top = last) back
                // into a boxed struct — the seam where a multi-slot value crosses into
                // still-boxed territory (an array element, enum payload, call, return).
                int sid = (int)operand_read(&frame->ip, OPK_IDX);
                const StructType *st = &vm->heap->prog->structs[sid];
                Value boxed = alloc_instance(RT(vm), sid, 0, 0, st->field_count);
                ObjStruct *s = AS_STRUCT(boxed);
                // Pack the leaf slots (mirror of unbox_flatten — reverse order) into the
                // packed buffer, recursing through inline nested struct fields (3b.5-B).
                box_pack(vm, sid, s->data);
                if (!push(vm, boxed)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_NEW_ENUM): {
                int type_id     = (int)operand_read(&frame->ip, OPK_IDX);
                int variant     = (int)operand_read(&frame->ip, OPK_IDX);
                int field_count = (int)operand_read(&frame->ip, OPK_IDX);
                Value instance = alloc_instance(RT(vm), type_id, variant, 1, field_count);
                for (int i = field_count - 1; i >= 0; i--) {
                    int k;
                    unsigned char *p = field_loc(RT(vm), AS_STRUCT(instance), i, &k);
                    value_unbox(p, k, pop(vm));
                }
                if (!push(vm, instance)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_GET_FIELD): {
                size_t index = operand_read(&frame->ip, OPK_IDX);
                Value receiver = pop(vm);
                int k;
                unsigned char *p = field_loc(RT(vm), AS_STRUCT(receiver), index, &k);
                if (k == AEK_INLINE_STRUCT) {
                    // Value semantics: materialise a fresh COPY of the inline nested struct
                    // (value-types 3b.5) — its bytes are independent of the parent.
                    int nsid = field_inline_sid(RT(vm), AS_STRUCT(receiver), index);
                    int fc   = vm->heap->prog->structs[nsid].field_count;
                    Value copy = alloc_instance(RT(vm), nsid, 0, 0, fc);
                    memcpy(AS_STRUCT(copy)->data, p,
                           (size_t)vm->heap->prog->structs[nsid].total_size);
                    struct_elem_retain(RT(vm), nsid, AS_STRUCT(copy)->data);  // no-op all-scalar
                    if (!push(vm, copy)) {
                        return VM_RUNTIME_ERROR;
                    }
                    VM_NEXT();
                }
                if (!push(vm, value_box(p, k))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_GET_FIELD_OWNED): {
                // The receiver is a fresh owned struct temporary: read the field, then
                // reclaim the receiver so it can't leak (OFI-027). A boxed field is
                // retained first, transferring the receiver's reference to the result;
                // a scalar field is independent (the struct owns nothing else of it).
                size_t index = operand_read(&frame->ip, OPK_IDX);
                Value receiver = pop(vm);
                int k;
                unsigned char *p = field_loc(RT(vm), AS_STRUCT(receiver), index, &k);
                if (k == AEK_INLINE_STRUCT) {
                    // Materialise the inline nested struct COPY from the receiver's bytes
                    // BEFORE reclaiming the receiver (value-types 3b.5 + OFI-027).
                    int nsid = field_inline_sid(RT(vm), AS_STRUCT(receiver), index);
                    int fc   = vm->heap->prog->structs[nsid].field_count;
                    Value copy = alloc_instance(RT(vm), nsid, 0, 0, fc);
                    memcpy(AS_STRUCT(copy)->data, p,
                           (size_t)vm->heap->prog->structs[nsid].total_size);
                    struct_elem_retain(RT(vm), nsid, AS_STRUCT(copy)->data);  // no-op all-scalar
                    drop_value(RT(vm), receiver);
                    if (!push(vm, copy)) {
                        return VM_RUNTIME_ERROR;
                    }
                    VM_NEXT();
                }
                Value field = value_box(p, k);
                if (k == AEK_BOXED && IS_OBJ(field)) {
                    OBJ_RETAIN(AS_OBJ(field));
                }
                drop_value(RT(vm), receiver);
                if (!push(vm, field)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_SET_FIELD): {
                // Stack: [receiver, value]. Mutate the field in place; an
                // assignment is a statement, so leave nothing behind. The struct
                // owned a boxed field's previous value, so release it before
                // overwriting (a no-op for packed scalar fields).
                size_t index = operand_read(&frame->ip, OPK_IDX);
                Value value = pop(vm);
                Value receiver = pop(vm);
                int k;
                unsigned char *p = field_loc(RT(vm), AS_STRUCT(receiver), index, &k);
                if (k == AEK_INLINE_STRUCT) {
                    // Overwrite an inline nested struct field: copy the new value's bytes in
                    // and reclaim its shell (value-types 3b.5; all-scalar ⇒ no old release).
                    int nsid = field_inline_sid(RT(vm), AS_STRUCT(receiver), index);
                    memcpy(p, AS_STRUCT(value)->data,
                           (size_t)vm->heap->prog->structs[nsid].total_size);
                    reclaim(RT(vm), AS_OBJ(value));
                    VM_NEXT();
                }
                if (k == AEK_BOXED) {
                    drop_value(RT(vm), value_box(p, k));
                }
                value_unbox(p, k, value);
                VM_NEXT();
            }
            VM_CASE(OP_GET_TAG): {
                // Read an enum value's variant index for match dispatch.
                Value receiver = pop(vm);
                if (!push(vm, INT_VAL(AS_STRUCT(receiver)->tag))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_NEW_ARRAY): {
                int count     = (int)operand_read(&frame->ip, OPK_IDX);
                uint8_t elem_kind = *frame->ip++;
                Value arr = alloc_array(RT(vm), count, elem_kind);
                // Stack has the elements in order; pop fills back-to-front.
                for (int i = count - 1; i >= 0; i--) {
                    array_unbox(AS_ARRAY(arr), (size_t)i, pop(vm));
                }
                if (!push(vm, arr)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_NEW_STRUCT_ARRAY): {
                // Build an inline struct array: copy each element struct's packed bytes
                // into the array buffer and reclaim the source struct (it is moved in).
                int count = (int)operand_read(&frame->ip, OPK_IDX);
                int struct_id = (int)operand_read(&frame->ip, OPK_IDX);
                Value arr = alloc_struct_array(RT(vm), count, struct_id);
                ObjArray *a = AS_ARRAY(arr);
                for (int i = count - 1; i >= 0; i--) {
                    Value v = pop(vm);
                    memcpy((unsigned char *)a->data + (size_t)i * a->elem_size,
                           AS_STRUCT(v)->data, a->elem_size);
                    reclaim(RT(vm), AS_OBJ(v));   // move-in: free the shell, fields transfer
                }
                if (!push(vm, arr)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_INDEX): {
                Value idx = pop(vm);
                Value arr = pop(vm);
                ObjArray *a = AS_ARRAY(arr);
                int64_t i = AS_INT(idx);
                if (i < 0 || (size_t)i >= a->length) {
                    FaultInt vals[2] = { { "index", i, 0 }, { "len", (int64_t)a->length, 0 } };
                    runtime_fault(vm, frame, "index_out_of_bounds",
                                  "array index out of bounds",
                                  "indexing requires 0 <= index < len",
                                  "valid indices are 0..len-1; guard with `if i < arr.len()`, or use `arr.get(i)` which returns an Option",
                                  vals, 2);
                    return VM_RUNTIME_ERROR;
                }
                if (a->elem_kind == AEK_INLINE_STRUCT) {
                    // Value semantics: materialise a fresh struct COPY of the element.
                    // OFI-027 makes this owned temp safe to drop after transient use.
                    int fc = vm->heap->prog->structs[a->elem_struct_id].field_count;
                    Value copy = alloc_instance(RT(vm), a->elem_struct_id, 0, 0, fc);
                    memcpy(AS_STRUCT(copy)->data,
                           (unsigned char *)a->data + (size_t)i * a->elem_size,
                           a->elem_size);
                    // A copy shares the element's boxed sub-fields with the array, so
                    // both own a reference: incref them (a no-op for all-scalar structs).
                    struct_elem_retain(RT(vm), a->elem_struct_id, AS_STRUCT(copy)->data);
                    if (!push(vm, copy)) {
                        return VM_RUNTIME_ERROR;
                    }
                    VM_NEXT();
                }
                if (a->elem_kind == AEK_BOXED) {
                    // A unique-owner aggregate element (value struct OR array) is read as an owned
                    // CLONE — safe to drop after transient use, not a borrow the array still owns
                    // (OFI-062/063). Refcounted elements (string/enum) keep the array_box borrow.
                    Value elem = ((Value *)a->data)[i];
                    if (IS_OBJ(elem) &&
                        ((AS_OBJ(elem)->type == OBJ_STRUCT && !AS_STRUCT(elem)->is_enum) ||
                         (AS_OBJ(elem)->type == OBJ_ARRAY && !((ObjArray *)AS_OBJ(elem))->borrowed))) {
                        if (!push(vm, clone_owned_else_borrow(RT(vm), elem))) {
                            return VM_RUNTIME_ERROR;
                        }
                        VM_NEXT();
                    }
                }
                if (!push(vm, array_box(a, (size_t)i))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_SET_INDEX): {
                // Stack: [array, index, value]. Mutate the element in place; an
                // assignment is a statement, so leave nothing behind. A boxed array
                // owned the previous element, so release it before overwriting.
                Value value = pop(vm);
                Value idx   = pop(vm);
                Value arr   = pop(vm);
                ObjArray *a = AS_ARRAY(arr);
                if (a->borrowed) {   // defense: a slice view is read-only
                    runtime_error("cannot assign through a slice view");
                    return VM_RUNTIME_ERROR;
                }
                int64_t i = AS_INT(idx);
                if (i < 0 || (size_t)i >= a->length) {
                    FaultInt vals[2] = { { "index", i, 0 }, { "len", (int64_t)a->length, 0 } };
                    runtime_fault(vm, frame, "index_out_of_bounds",
                                  "array index out of bounds",
                                  "indexing requires 0 <= index < len",
                                  "valid indices are 0..len-1; guard with `if i < arr.len()`, or use `arr.get(i)` which returns an Option",
                                  vals, 2);
                    return VM_RUNTIME_ERROR;
                }
                if (a->elem_kind == AEK_INLINE_STRUCT) {
                    // Release the old element's boxed sub-fields, then overwrite with the
                    // new struct's bytes and free its shell (the new value moves in).
                    unsigned char *slot =
                        (unsigned char *)a->data + (size_t)i * a->elem_size;
                    struct_elem_release(RT(vm), a->elem_struct_id, slot);
                    memcpy(slot, AS_STRUCT(value)->data, a->elem_size);
                    reclaim(RT(vm), AS_OBJ(value));
                    VM_NEXT();
                }
                if (a->elem_kind == AEK_BOXED) {
                    drop_value(RT(vm), ((Value *)a->data)[i]);
                }
                array_unbox(a, (size_t)i, value);
                VM_NEXT();
            }
            VM_CASE(OP_ARRAY_LEN): {
                Value arr = pop(vm);
                if (!push(vm, INT_VAL((int64_t)AS_ARRAY(arr)->length))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_ARRAY_APPEND): {
                // Stack: [array, value]. Grow the buffer if full (doubling, from a
                // small base), store the value, and leave a unit result for the
                // enclosing statement to discard. The value moves into the array.
                Value value = pop(vm);
                Value arr   = pop(vm);
                ObjArray *a = AS_ARRAY(arr);
                if (a->borrowed) {   // defense: the checker forbids mutating a slice/frozen array
                    runtime_error("cannot append to a slice view");
                    return VM_RUNTIME_ERROR;
                }
                if (a->length == a->capacity) {
                    size_t newcap = a->capacity < 4 ? 4 : a->capacity * 2;
                    void *nb = realloc(a->data, newcap * a->elem_size);
                    if (nb == NULL) {
                        fprintf(stderr, "emberc: out of memory growing an array\n");
                        exit(70);
                    }
                    a->data     = nb;
                    a->capacity = newcap;
                }
                if (a->elem_kind == AEK_INLINE_STRUCT) {
                    memcpy((unsigned char *)a->data + a->length * a->elem_size,
                           AS_STRUCT(value)->data, a->elem_size);
                    a->length++;
                    reclaim(RT(vm), AS_OBJ(value));   // move-in: free the shell, fields transfer
                } else {
                    array_unbox(a, a->length++, value);
                }
                if (!push(vm, INT_VAL(0))) {       // unit (the statement pops it)
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_ARRAY_POP): {
                // Stack: [array]. Remove and return the last element. Its ownership
                // moves to the caller; shrinking `length` excludes it from the
                // array's own later cleanup, so it is not double-freed.
                Value arr = pop(vm);
                ObjArray *a = AS_ARRAY(arr);
                if (a->borrowed) {   // defense: a slice view is read-only
                    runtime_error("cannot remove_last from a slice view");
                    return VM_RUNTIME_ERROR;
                }
                if (a->length == 0) {
                    runtime_error("remove_last on an empty array");
                    return VM_RUNTIME_ERROR;
                }
                a->length--;
                if (a->elem_kind == AEK_INLINE_STRUCT) {
                    int fc = vm->heap->prog->structs[a->elem_struct_id].field_count;
                    Value copy = alloc_instance(RT(vm), a->elem_struct_id, 0, 0, fc);
                    memcpy(AS_STRUCT(copy)->data,
                           (unsigned char *)a->data + a->length * a->elem_size,
                           a->elem_size);
                    if (!push(vm, copy)) {
                        return VM_RUNTIME_ERROR;
                    }
                    VM_NEXT();
                }
                if (!push(vm, array_box(a, a->length))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_ARRAY_REMOVE_AT): {
                // Stack: [array, index]. Remove + return element[index], shifting the tail down one
                // slot. The removed element's ownership MOVES to the caller (boxed without a retain);
                // the shift relocates every later element's single owner; the now-excess last slot
                // falls outside the shrunk length, so nothing is double-freed or leaked.
                Value iv  = pop(vm);
                Value arr = pop(vm);
                ObjArray *a = AS_ARRAY(arr);
                if (a->borrowed) {   // a slice view is read-only
                    runtime_error("cannot remove_at from a slice view");
                    return VM_RUNTIME_ERROR;
                }
                int64_t idx = AS_INT(iv);
                if (idx < 0 || (size_t)idx >= a->length) {
                    FaultInt vals[2] = { { "index", idx, 0 }, { "len", (int64_t)a->length, 0 } };
                    runtime_fault(vm, frame, "remove_at_out_of_range",
                                  "remove_at index out of range",
                                  "remove_at requires 0 <= index < len",
                                  "valid indices are 0..len-1; check `i < arr.len()` before removing",
                                  vals, 2);
                    return VM_RUNTIME_ERROR;
                }
                Value removed;
                if (a->elem_kind == AEK_INLINE_STRUCT) {
                    int fc = vm->heap->prog->structs[a->elem_struct_id].field_count;
                    removed = alloc_instance(RT(vm), a->elem_struct_id, 0, 0, fc);
                    memcpy(AS_STRUCT(removed)->data,
                           (unsigned char *)a->data + (size_t)idx * a->elem_size, a->elem_size);
                } else {
                    removed = array_box(a, (size_t)idx);   // move out (no retain)
                }
                unsigned char *base = (unsigned char *)a->data;
                memmove(base + (size_t)idx * a->elem_size,
                        base + ((size_t)idx + 1) * a->elem_size,
                        (a->length - (size_t)idx - 1) * a->elem_size);
                a->length--;
                if (!push(vm, removed)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_SLICE): {
                // Stack: [array, lo, hi] → a borrowed Slice<T> view over array[lo..hi].
                Value hiv = pop(vm);
                Value lov = pop(vm);
                Value arr = pop(vm);
                ObjArray *a = AS_ARRAY(arr);
                int64_t lo = AS_INT(lov), hi = AS_INT(hiv);
                if (lo < 0 || hi < lo || (size_t)hi > a->length) {
                    FaultInt vals[3] = { { "lo", lo, 0 }, { "hi", hi, 0 }, { "len", (int64_t)a->length, 0 } };
                    runtime_fault(vm, frame, "slice_out_of_range", "slice bounds out of range",
                                  "slicing requires 0 <= lo <= hi <= len",
                                  "clamp the bounds to 0..len, with lo <= hi",
                                  vals, 3);
                    return VM_RUNTIME_ERROR;
                }
                if (!push(vm, alloc_slice(RT(vm), a, (size_t)lo, (size_t)hi))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_SLICE_COPY): {
                // Stack: [array, lo, hi] → a fresh OWNED [T] copy of array[lo..hi]. The copy owns
                // its buffer and elements (boxed elements are retained), so it can escape freely.
                Value hiv = pop(vm);
                Value lov = pop(vm);
                Value arr = pop(vm);
                ObjArray *a = AS_ARRAY(arr);
                int64_t lo = AS_INT(lov), hi = AS_INT(hiv);
                if (lo < 0 || hi < lo || (size_t)hi > a->length) {
                    FaultInt vals[3] = { { "lo", lo, 0 }, { "hi", hi, 0 }, { "len", (int64_t)a->length, 0 } };
                    runtime_fault(vm, frame, "slice_out_of_range", "slice bounds out of range",
                                  "slicing requires 0 <= lo <= hi <= len",
                                  "clamp the bounds to 0..len, with lo <= hi",
                                  vals, 3);
                    return VM_RUNTIME_ERROR;
                }
                size_t n = (size_t)(hi - lo);
                // An INLINE-STRUCT array's per-element width is the struct's total_size, which only
                // alloc_struct_array knows — alloc_array(elem_kind) would size each element at
                // sizeof(Value) and the memcpy below would overflow the buffer (OFI-083). Use the
                // struct-aware allocator so o->elem_size == a->elem_size.
                Value out;
                if (a->elem_kind == AEK_INLINE_STRUCT && a->elem_struct_id >= 0) {
                    out = alloc_struct_array(RT(vm), n, a->elem_struct_id);
                } else {
                    out = alloc_array(RT(vm), n, a->elem_kind);
                }
                ObjArray *o = AS_ARRAY(out);
                o->elem_struct_id = a->elem_struct_id;
                if (n > 0) {
                    memcpy(o->data, (unsigned char *)a->data + (size_t)lo * a->elem_size,
                           n * a->elem_size);
                    if (a->elem_kind == AEK_BOXED) {           // retain each copied heap element
                        for (size_t i = 0; i < n; i++) {       // (string/enum/closure: refcounted;
                            Value ev = ((Value *)o->data)[i];  //  the checker forbids array elems)
                            if (IS_OBJ(ev)) {
                                OBJ_RETAIN(AS_OBJ(ev));
                            }
                        }
                    } else if (a->elem_kind == AEK_INLINE_STRUCT) {
                        for (size_t i = 0; i < n; i++) {
                            struct_elem_retain(RT(vm), o->elem_struct_id,
                                               (unsigned char *)o->data + i * o->elem_size);
                        }
                    }
                }
                if (!push(vm, out)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_STR_LEN): {
                // Stack: [string]. Byte length, O(1) (code-point count is OP_STR_CHAR_COUNT).
                Value s = pop(vm);
                if (!push(vm, INT_VAL((int64_t)AS_STRING(s)->length))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_STR_CHARS): {
                // Stack: [string] → [string], one string per Unicode code point (UTF-8 decoded;
                // an invalid byte yields a U+FFFD string). Two passes: count, then fill.
                Value sv = pop(vm);
                ObjString *s = AS_STRING(sv);
                const unsigned char *b = (const unsigned char *)s->chars;
                size_t n = 0;
                for (size_t i = 0; i < s->length; ) {
                    uint32_t cp;
                    i += (size_t)utf8_decode(b + i, s->length - i, &cp);
                    n++;
                }
                Value arr = alloc_array(RT(vm), n, AEK_BOXED);
                size_t k = 0;
                for (size_t i = 0; i < s->length; ) {
                    uint32_t cp;
                    int w = utf8_decode(b + i, s->length - i, &cp);
                    unsigned char buf[4];
                    int wn = utf8_encode(cp, buf);          // re-encode so an invalid byte → U+FFFD
                    ObjString *ch = make_string(RT(vm), (size_t)wn);
                    memcpy(ch->chars, buf, (size_t)wn);
                    array_unbox(AS_ARRAY(arr), k++, OBJ_VAL(ch));
                    i += (size_t)w;
                }
                if (!push(vm, arr)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_STR_CHAR_COUNT): {
                // Stack: [string] → int. Number of Unicode code points (O(n)).
                Value sv = pop(vm);
                ObjString *s = AS_STRING(sv);
                const unsigned char *b = (const unsigned char *)s->chars;
                size_t n = 0;
                for (size_t i = 0; i < s->length; ) {
                    uint32_t cp;
                    i += (size_t)utf8_decode(b + i, s->length - i, &cp);
                    n++;
                }
                if (!push(vm, INT_VAL((int64_t)n))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_STR_BYTES): {
                // Stack: [string] → [u8]. The raw UTF-8 bytes (useful for FFI buffers).
                Value sv = pop(vm);
                ObjString *s = AS_STRING(sv);
                Value arr = alloc_array(RT(vm), s->length, AEK_U8);
                for (size_t i = 0; i < s->length; i++) {
                    array_unbox(AS_ARRAY(arr), i, INT_VAL((int64_t)(unsigned char)s->chars[i]));
                }
                if (!push(vm, arr)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_STR_SPLIT): {
                // Stack: [string, separator] → [string]. Splits on each
                // non-overlapping occurrence of the separator. An empty separator
                // yields the whole string as the single piece.
                Value sepv = pop(vm);
                Value sv   = pop(vm);
                ObjString *s   = AS_STRING(sv);
                ObjString *sep = AS_STRING(sepv);
                size_t slen = s->length, seplen = sep->length;
                size_t pieces = 1;
                if (seplen > 0) {
                    for (size_t i = 0; i + seplen <= slen; ) {
                        if (memcmp(s->chars + i, sep->chars, seplen) == 0) {
                            pieces++;
                            i += seplen;
                        } else {
                            i++;
                        }
                    }
                }
                Value arr = alloc_array(RT(vm), pieces, AEK_BOXED);
                if (seplen == 0) {
                    ObjString *whole = make_string(RT(vm), slen);
                    memcpy(whole->chars, s->chars, slen);
                    array_unbox(AS_ARRAY(arr), 0, OBJ_VAL(whole));
                } else {
                    size_t start = 0, idx = 0, i = 0;
                    while (i + seplen <= slen) {
                        if (memcmp(s->chars + i, sep->chars, seplen) == 0) {
                            size_t len = i - start;
                            ObjString *piece = make_string(RT(vm), len);
                            memcpy(piece->chars, s->chars + start, len);
                            array_unbox(AS_ARRAY(arr), idx++, OBJ_VAL(piece));
                            i += seplen;
                            start = i;
                        } else {
                            i++;
                        }
                    }
                    size_t len = slen - start;
                    ObjString *piece = make_string(RT(vm), len);
                    memcpy(piece->chars, s->chars + start, len);
                    array_unbox(AS_ARRAY(arr), idx++, OBJ_VAL(piece));
                }
                if (!push(vm, arr)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_STR_PARSE_INT): {
                // Stack: [string] → Option<int>. Strict: optional leading +/-, then
                // one or more ASCII digits, nothing else. Empty, malformed, or
                // out-of-range input yields None. Operands carry the Some/None tags.
                int enum_id  = (int)operand_read(&frame->ip, OPK_IDX);
                int some_tag = (int)operand_read(&frame->ip, OPK_IDX);
                int none_tag = (int)operand_read(&frame->ip, OPK_IDX);
                Value sv = pop(vm);
                ObjString *s = AS_STRING(sv);
                size_t n = s->length, i = 0;
                int ok = n > 0, neg = 0;
                int64_t result = 0;
                if (ok && (s->chars[0] == '+' || s->chars[0] == '-')) {
                    neg = (s->chars[0] == '-');
                    i = 1;
                    if (i == n) {
                        ok = 0;   // a lone sign
                    }
                }
                for (; ok && i < n; i++) {
                    char ch = s->chars[i];
                    if (ch < '0' || ch > '9') {
                        ok = 0;
                        break;
                    }
                    if (__builtin_mul_overflow(result, (int64_t)10, &result) ||
                        __builtin_add_overflow(result, (int64_t)(ch - '0'), &result)) {
                        ok = 0;   // magnitude beyond int64
                        break;
                    }
                }
                Value opt;
                if (ok) {
                    opt = alloc_instance(RT(vm), enum_id, some_tag, 1, 1);
                    value_unbox(AS_STRUCT(opt)->data, AEK_BOXED,
                                INT_VAL(neg ? -result : result));
                } else {
                    opt = alloc_instance(RT(vm), enum_id, none_tag, 1, 0);
                }
                if (!push(vm, opt)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_INT_TO_FLOAT): {
                Value n = pop(vm);
                if (!push(vm, FLOAT_VAL((double)AS_INT(n)))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_FLOAT_TO_INT): {
                // Truncate toward zero, matching C's double→int64 conversion.
                Value f = pop(vm);
                if (!push(vm, INT_VAL((int64_t)AS_FLOAT(f)))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_CONV): {
                // Numeric conversion. Operand: the target kind. A float target
                // (8 = f32 rounds, 9 = f64 passes through) converts a float; an
                // integer target narrows with a range trap, except u64 (kind 7),
                // which is a lossless bit-reinterpretation of any 64-bit pattern.
                uint8_t nk = *frame->ip++;
                if (nk == 8 || nk == 9) {
                    double f = AS_FLOAT(pop(vm));
                    if (nk == 8) { f = (float)f; }
                    if (!push(vm, FLOAT_VAL(f))) {
                        return VM_RUNTIME_ERROR;
                    }
                    VM_NEXT();
                }
                int64_t v = AS_INT(pop(vm));
                if (nk != 7 && (v < NK_MIN[nk] || v > NK_MAX[nk])) {
                    FaultInt vals[3] = { { "value", v, 0 }, { "min", NK_MIN[nk], 0 }, { "max", NK_MAX[nk], 0 } };
                    runtime_fault(vm, frame, "value_out_of_range",
                                  "value out of range for the target integer type",
                                  "the value must fit the target integer type's range",
                                  "the value is outside [min, max]; use a wider type, or check the range first",
                                  vals, 3);
                    return VM_RUNTIME_ERROR;
                }
                if (!push(vm, INT_VAL(v))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_CLOCK): {
                // A monotonic clock in seconds — for timing, immune to wall-clock
                // adjustments. Resolution is the platform's (nanoseconds here).
                struct timespec ts;
                clock_gettime(CLOCK_MONOTONIC, &ts);
                double secs = (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
                secs = nondet_scalar(vm, NONDET_CLOCK, secs);
                if (!push(vm, FLOAT_VAL(secs))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_TO_STRING): {
                // Render a value as a string for interpolation (or to print a u64
                // unsigned). Operand: the numeric kind — kind 7 (u64) renders the
                // int64 bits as unsigned. The checker only lets a number/string here.
                uint8_t nk = *frame->ip++;
                Value v = pop(vm);
                if (IS_STRING(v)) {
                    // Already a string: return it as an OWNED reference (OFI-059). The interpolation
                    // fold concatenates with OP_CONCAT, which CONSUMES each operand, so the operand
                    // must own a reference — retaining here balances that release and keeps the
                    // source (which may be a borrowed local) alive. A no-op for a fresh result.
                    OBJ_RETAIN(AS_OBJ(v));
                    if (!push(vm, v)) {
                        return VM_RUNTIME_ERROR;
                    }
                    VM_NEXT();
                }
                char buf[32];
                int n;
                if (nk == 10) {              // a bool renders as true/false, not 1/0
                    n = snprintf(buf, sizeof buf, "%s", AS_INT(v) != 0 ? "true" : "false");
                } else if (IS_FLOAT(v)) {
                    n = snprintf(buf, sizeof buf, "%g", AS_FLOAT(v));
                } else if (nk == 7) {
                    n = snprintf(buf, sizeof buf, "%llu",
                                 (unsigned long long)(uint64_t)AS_INT(v));
                } else {
                    n = snprintf(buf, sizeof buf, "%lld", (long long)AS_INT(v));
                }
                ObjString *s = make_string(RT(vm), (size_t)n);
                memcpy(s->chars, buf, (size_t)n);
                if (!push(vm, OBJ_VAL(s))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_CALL): {
                size_t func_index = operand_read(&frame->ip, OPK_IDX);
                size_t argc       = operand_read(&frame->ip, OPK_IDX);
                if (vm->frame_count == FRAMES_MAX) {
                    runtime_error("call depth exceeded");
                    return VM_RUNTIME_ERROR;
                }
                const Function *callee = &vm->heap->prog->functions[func_index];
                CallFrame *new_frame = &vm->frames[vm->frame_count++];
                vm->route_hop_count = 0;   // OFI-108: a call ends any prior `?`-propagation chain
                new_frame->fn    = callee;
                new_frame->ip    = callee->chunk.code;
                new_frame->slots = vm->sp - argc;
                frame = new_frame;
                VM_NEXT();
            }
            VM_CASE(OP_CALL_INDIRECT): {
                // The function-table index is computed at run time (popped from the
                // top of the stack — e.g. read out of a witness), the arguments sit
                // below it. Used for bound-method dispatch through a witness.
                size_t argc = operand_read(&frame->ip, OPK_IDX);
                int64_t func_index = AS_INT(pop(vm));
                if (func_index >= WITNESS_NATIVE_BASE) {
                    // A built-in key type's Hash/Eq witness: call the native shim
                    // instead of entering an Ember frame (no such function exists).
                    int nid = (int)(func_index - WITNESS_NATIVE_BASE);
                    Value result = call_native(vm, nid, vm->sp - argc, argc);
                    vm->sp -= argc;
                    if (!push(vm, result)) {
                        return VM_RUNTIME_ERROR;
                    }
                    VM_NEXT();
                }
                if (vm->frame_count == FRAMES_MAX) {
                    runtime_error("call depth exceeded");
                    return VM_RUNTIME_ERROR;
                }
                const Function *callee = &vm->heap->prog->functions[func_index];
                CallFrame *new_frame = &vm->frames[vm->frame_count++];
                vm->route_hop_count = 0;   // OFI-108: a call ends any prior `?`-propagation chain
                new_frame->fn    = callee;
                new_frame->ip    = callee->chunk.code;
                new_frame->slots = vm->sp - argc;
                frame = new_frame;
                VM_NEXT();
            }
            VM_CASE(OP_MAKE_DYN): {
                // Box a struct receiver + its vtable into an interface value. Stack:
                // [..., receiver, vtable] (vtable on top). The new value owns both.
                Value vtable   = pop(vm);
                Value receiver = pop(vm);
                Value iface    = alloc_interface(RT(vm), receiver, vtable);
                if (!push(vm, iface)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_CALL_DYN): {
                // Dynamic dispatch on an interface value. Stack: [iface, arg1..argN].
                // Read the method's fn-index from the value's vtable, replace the iface
                // slot with the receiver (self), and call — like OP_CALL_INDIRECT but the
                // function comes from the vtable, not the stack. Self is borrowed (the
                // owning binding still holds the interface value), so it is not dropped.
                size_t slot = operand_read(&frame->ip, OPK_IDX);
                size_t argc = operand_read(&frame->ip, OPK_IDX);
                Value *ifacep = vm->sp - argc - 1;
                ObjInterface *it = AS_INTERFACE(*ifacep);
                int k;
                unsigned char *p = field_loc(RT(vm), AS_STRUCT(it->vtable), slot, &k);
                int64_t func_index = AS_INT(value_box(p, k));
                *ifacep = it->receiver;   // self = the boxed receiver (a borrow)
                if (vm->frame_count == FRAMES_MAX) {
                    runtime_error("call depth exceeded");
                    return VM_RUNTIME_ERROR;
                }
                const Function *callee = &vm->heap->prog->functions[func_index];
                CallFrame *new_frame = &vm->frames[vm->frame_count++];
                vm->route_hop_count = 0;   // OFI-108: a call ends any prior `?`-propagation chain
                new_frame->fn    = callee;
                new_frame->ip    = callee->chunk.code;
                new_frame->slots = vm->sp - (argc + 1);   // self + explicit args
                frame = new_frame;
                VM_NEXT();
            }
            VM_CASE(OP_MAKE_CLOSURE): {
                // Build a function value: fn-table index + `capcount` captures sitting
                // on top of the stack (lowest = captures[0]). make_closure takes its
                // own reference to each, so the pushed borrows are simply popped.
                size_t fn_index = operand_read(&frame->ip, OPK_IDX);
                size_t capcount = operand_read(&frame->ip, OPK_IDX);
                ObjClosure *cl = make_closure(vm, fn_index, vm->sp - capcount,
                                              capcount);
                vm->sp -= capcount;
                if (!push(vm, OBJ_VAL(cl))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_CALL_CLOSURE): {
                // The closure sits on top, its `argc` args below it. The lifted
                // function's locals are [captures..., args...], so splice the
                // captures in ahead of the args (incref'd: the callee owns its copies
                // while the closure keeps its own references for the next call).
                int argc = (int)operand_read(&frame->ip, OPK_IDX);
                Value clo = pop(vm);
                if (!IS_CLOSURE(clo)) {
                    runtime_error("call of a value that is not a function");
                    return VM_RUNTIME_ERROR;
                }
                ObjClosure *cl = AS_CLOSURE(clo);
                int m = cl->capture_count;
                if (vm->frame_count == FRAMES_MAX) {
                    runtime_error("call depth exceeded");
                    return VM_RUNTIME_ERROR;
                }
                if (vm->sp + m > vm->stack + STACK_MAX) {
                    runtime_error("stack overflow");
                    return VM_RUNTIME_ERROR;
                }
                Value *base = vm->sp - argc;
                // Retain each heap argument here, at run time, where its true
                // representation is known. The call site cannot: inside an erased
                // generic body an argument's static type may be a bare `T`, so the
                // checker emits no incref there — but the callee (a lifted lambda
                // or named function) has CONCRETE parameter types and releases
                // refcounted ones on return. Without this +1 every such call
                // underflows the refcount and frees a value the caller still owns.
                // For unique owners (structs/arrays) the refcount is ignored, so
                // this is a no-op and they pass as plain borrows. A retained
                // temporary leaks rather than crashes — the same sound convention
                // erased generic calls already follow (OFI-009).
                for (int i = 0; i < argc; i++) {
                    if (IS_OBJ(base[i])) {
                        OBJ_RETAIN(AS_OBJ(base[i]));
                    }
                }
                if (m > 0) {
                    memmove(base + m, base, (size_t)argc * sizeof(Value));
                    for (int i = 0; i < m; i++) {
                        Value v = cl->captures[i];
                        if (IS_OBJ(v)) {
                            OBJ_RETAIN(AS_OBJ(v));
                        }
                        base[i] = v;
                    }
                    vm->sp += m;
                }
                const Function *callee = &vm->heap->prog->functions[cl->fn_index];
                CallFrame *new_frame = &vm->frames[vm->frame_count++];
                vm->route_hop_count = 0;   // OFI-108: a call ends any prior `?`-propagation chain
                new_frame->fn    = callee;
                new_frame->ip    = callee->chunk.code;
                new_frame->slots = base;
                frame = new_frame;
                VM_NEXT();
            }
            VM_CASE(OP_CALL_NATIVE): {
                size_t native_id = operand_read(&frame->ip, OPK_IDX);
                size_t argc      = operand_read(&frame->ip, OPK_IDX);
                Value result = call_native(vm, native_id, vm->sp - argc, argc);
                vm->sp -= argc;   // pop the arguments
                if (vm->exit_requested) {
                    return VM_OK;   // exit(code): unwind the interpreter cleanly
                }
                if (!push(vm, result)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_CALL_C): {
                // Foreign (C) call (FFI, §5h / 3b.6): the arguments sit on the stack already
                // FLATTENED to their scalar leaves; pass them to the registry wrapper, which
                // reassembles any concrete C struct and returns its result leaves. The 16-bit
                // operand is the return struct id (0xFFFF = scalar): reassemble a boxed Ember
                // struct from the result leaves, or push the single scalar.
                size_t index  = operand_read(&frame->ip, OPK_IDX);
                int    retsid = (int)operand_read(&frame->ip, OPK_IDX);
                int in_leaves = cextern_sig(index)->in_leaves;
                Value out[CEXTERN_MAX_LEAVES];
                int n_out;
                if (vm->nondet_mode == 2) {
                    // Replay (§5j): a C call's result may be nondeterministic, so return the
                    // recorded leaves and make no real foreign call (its side effects don't recur).
                    n_out = cextern_sig(index)->out_leaves;
                    for (int i = 0; i < n_out; i++) {
                        out[i] = nondet_replay_ffi(vm);
                    }
                    vm->sp -= in_leaves;
                } else {
                    n_out = cextern_call(index, vm->sp - in_leaves, out);
                    vm->sp -= in_leaves;
                    if (vm->nondet_mode == 1) {   // record each result leaf for a future replay
                        for (int i = 0; i < n_out; i++) {
                            nondet_record_ffi(vm, out[i]);
                        }
                    }
                }
                if (cextern_sig(index)->ret_is_string) {
                    // A C-owned returned string (FFI copy-on-return, §5h / OFI-043): out[0] is a
                    // malloc'd char* — copy its bytes into an owned Ember string, then free the C
                    // buffer. (In replay there is no live pointer, so yield an empty string —
                    // string-returning FFI is not replay-safe, like a mut buffer; OFI-044.)
                    ObjString *s;
                    if (vm->nondet_mode == 2 || n_out == 0) {
                        s = make_string(RT(vm), 0);
                    } else {
                        char *p = (char *)(intptr_t)AS_INT(out[0]);
                        size_t len = (p != NULL) ? strlen(p) : 0;
                        s = make_string(RT(vm), len);
                        if (p != NULL) {
                            memcpy(s->chars, p, len);
                            free(p);
                        }
                    }
                    if (!push(vm, OBJ_VAL(s))) {
                        return VM_RUNTIME_ERROR;
                    }
                } else if (retsid == 0xFFFF) {
                    if (!push(vm, n_out > 0 ? out[0] : INT_VAL(0))) {
                        return VM_RUNTIME_ERROR;
                    }
                } else {
                    int fc = vm->heap->prog->structs[retsid].field_count;
                    Value boxed = alloc_instance(RT(vm), retsid, 0, 0, fc);
                    int idx = 0;
                    pack_from_buf(vm, retsid, AS_STRUCT(boxed)->data, out, &idx);
                    if (!push(vm, boxed)) {
                        return VM_RUNTIME_ERROR;
                    }
                }
                VM_NEXT();
            }
            VM_CASE(OP_CHANNEL_NEW): {
                Value cap = pop(vm);
                if (!push(vm, alloc_channel(vm, (int)AS_INT(cap)))) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_SEND): {
                // Stack: [channel, value]. Enqueue if there is room, else block.
                ObjChannel *ch = AS_CHANNEL(vm->sp[-2]);
#if EMBER_MN
                // M:N: park the FIBER (not the OS thread) while full — observe-full + register-on-
                // FIFO + commit-to-yield are ONE critical section under ch->lock, so a receiver that
                // frees space can't miss us (lost-wakeup-free). A wake re-queues us; we re-run this op.
                {
                    Nursery *cn = vm->current->nursery;
                    if (cn != NULL && __atomic_load_n(&cn->cancel, __ATOMIC_ACQUIRE)) {
                        return VM_CANCELLED;
                    }
                }
                pthread_mutex_lock(&ch->lock);
                if (ch->closed) {                           // send on a closed channel is an error (OFI-086)
                    pthread_mutex_unlock(&ch->lock);
                    runtime_error("send on a closed channel");
                    return VM_RUNTIME_ERROR;
                }
                if (ch->count == ch->capacity) {            // full → park on the sender FIFO
                    frame->ip--;                            // re-run OP_SEND on resume
                    vm->current->block_channel = ch;
                    vm->current->block_is_send = 1;
                    ch_park(ch, vm->current, 1);
                    pthread_mutex_unlock(&ch->lock);
                    return VM_YIELD;
                }
                ch->buffer[(ch->head + ch->count) % ch->capacity] = vm->sp[-1];
                ch->count++;
                Fiber *waiter_rx = ch_unpark(ch, 0);        // a receiver can now proceed
                vm->current->block_channel = NULL;
                pthread_mutex_unlock(&ch->lock);
                if (waiter_rx != NULL) {                    // requeue OUTSIDE ch->lock (lock order)
                    requeue(vm->sched, waiter_rx);
                }
                vm->sp -= 2;                                // pop channel + value
                if (!push(vm, INT_VAL(0))) {               // unit result (statement pops it)
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
#elif EMBER_PARALLEL
                // Parallel: a peer on another core drains the queue, so park this
                // OS thread on the condvar while full; the receiver wakes us — or
                // the deadlock detector does, if every sibling is also stuck.
                pthread_mutex_lock(&ch->lock);
                if (ch->closed) {                      // send on a closed channel is an error (OFI-086)
                    pthread_mutex_unlock(&ch->lock);
                    runtime_error("send on a closed channel");
                    return VM_RUNTIME_ERROR;
                }
                int parked_here = 0;
                while (ch->count == ch->capacity && !nursery_deadlocked(vm)) {
                    if (!parked_here) {
                        parked_here = 1;
                        ch->send_waiters++;            // a receiver may now skip signalling
                        nursery_park(vm, ch, 1);       // 1 = blocked on send-full
                        continue;                      // park() may have just set deadlock
                    }
                    pthread_cond_wait(&ch->not_full, &ch->lock);
                }
                if (parked_here) {
                    ch->send_waiters--;
                    nursery_unpark(vm);
                }
                if (ch->count == ch->capacity) {       // still full ⇒ deadlock woke us
                    pthread_mutex_unlock(&ch->lock);
                    return VM_RUNTIME_ERROR;            // detector already reported it
                }
                ch->buffer[(ch->head + ch->count) % ch->capacity] = vm->sp[-1];
                ch->count++;
                if (ch->recv_waiters > 0) {            // only signal when someone is parked —
                    pthread_cond_signal(&ch->not_empty); // skips a needless syscall under the
                }                                        // lock when the consumer is keeping up
                pthread_mutex_unlock(&ch->lock);
                vm->sp -= 2;                            // pop channel + value
                if (!push(vm, INT_VAL(0))) {           // unit result (statement pops it)
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
#else
                // Serial: rewind to retry this op when the scheduler resumes us.
                if (ch->closed) {                      // send on a closed channel is an error (OFI-086)
                    runtime_error("send on a closed channel");
                    return VM_RUNTIME_ERROR;
                }
                if (ch->count == ch->capacity) {
                    frame->ip--;                       // retry OP_SEND on resume
                    vm->current->block_channel = ch;
                    vm->current->block_is_send = 1;
                    return VM_YIELD;
                }
                ch->buffer[(ch->head + ch->count) % ch->capacity] = vm->sp[-1];
                ch->count++;
                vm->sp -= 2;                            // pop channel + value
                vm->current->block_channel = NULL;
                if (!push(vm, INT_VAL(0))) {           // unit result (statement pops it)
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
#endif
            }
            VM_CASE(OP_RECV): {
                // Stack: [channel]. recv yields an Option: Some(v) if a value is
                // queued, None if the channel is closed and drained. Operands carry
                // the Option enum's type id and the Some/None variant tags.
#if !EMBER_PARALLEL || EMBER_MN
                const uint8_t *recv_op = frame->ip - 1;   // opcode start, for the yield-and-retry path
                                                          // (1:1 parallel parks on a condvar — no rewind)
#endif
                int enum_id     = (int)operand_read(&frame->ip, OPK_IDX);
                int some_tag    = (int)operand_read(&frame->ip, OPK_IDX);
                int none_tag    = (int)operand_read(&frame->ip, OPK_IDX);
                ObjChannel *ch = AS_CHANNEL(vm->sp[-1]);
#if EMBER_MN
                // M:N: park the FIBER while the queue is empty + open — observe + register + commit
                // under ch->lock (lost-wakeup-free). A sender / close re-queues us; we re-run this op.
                {
                    Nursery *cn = vm->current->nursery;
                    if (cn != NULL && __atomic_load_n(&cn->cancel, __ATOMIC_ACQUIRE)) {
                        return VM_CANCELLED;
                    }
                }
                pthread_mutex_lock(&ch->lock);
                if (ch->count == 0 && !ch->closed) {        // empty + open → park on the receiver FIFO
                    frame->ip = recv_op;                    // re-run OP_RECV on resume (operands re-read)
                    vm->current->block_channel = ch;
                    vm->current->block_is_send = 0;
                    ch_park(ch, vm->current, 0);
                    pthread_mutex_unlock(&ch->lock);
                    return VM_YIELD;
                }
                if (ch->count == 0) {                       // drained + closed → None
                    pthread_mutex_unlock(&ch->lock);
                    Value none = alloc_instance(RT(vm), enum_id, none_tag, 1, 0);
                    vm->sp[-1] = none;
                    vm->current->block_channel = NULL;
                    VM_NEXT();
                }
                Value v = ch->buffer[ch->head];
                ch->head = (ch->head + 1) % ch->capacity;
                ch->count--;
                Fiber *waiter_tx = ch_unpark(ch, 1);        // a sender can now proceed
                vm->current->block_channel = NULL;
                pthread_mutex_unlock(&ch->lock);
                if (waiter_tx != NULL) {
                    requeue(vm->sched, waiter_tx);
                }
                Value some = alloc_instance(RT(vm), enum_id, some_tag, 1, 1);
                value_unbox(AS_STRUCT(some)->data, AEK_BOXED, v);
                vm->sp[-1] = some;                          // replace channel with Some(v)
                VM_NEXT();
#elif EMBER_PARALLEL
                // Parallel: park this OS thread on the condvar while the queue is
                // empty and open; a sender (or close) on any core wakes us. The
                // Option is allocated AFTER unlocking, so we never hold the channel
                // lock and the heap lock at once (no lock-order deadlock).
                pthread_mutex_lock(&ch->lock);
                int parked_here = 0;
                while (ch->count == 0 && !ch->closed && !nursery_deadlocked(vm)) {
                    if (!parked_here) {
                        parked_here = 1;
                        ch->recv_waiters++;            // a sender may now skip signalling
                        nursery_park(vm, ch, 0);       // 0 = blocked on recv-empty
                        continue;                      // park() may have just set deadlock
                    }
                    pthread_cond_wait(&ch->not_empty, &ch->lock);
                }
                if (parked_here) {
                    ch->recv_waiters--;
                    nursery_unpark(vm);
                }
                if (ch->count == 0 && !ch->closed) {   // empty, open ⇒ deadlock woke us
                    pthread_mutex_unlock(&ch->lock);
                    return VM_RUNTIME_ERROR;            // detector already reported it
                }
                if (ch->count == 0) {                  // drained + closed ⇒ None
                    pthread_mutex_unlock(&ch->lock);
                    Value none = alloc_instance(RT(vm), enum_id, none_tag, 1, 0);
                    vm->sp[-1] = none;
                    VM_NEXT();
                }
                Value v = ch->buffer[ch->head];
                ch->head = (ch->head + 1) % ch->capacity;
                ch->count--;
                if (ch->send_waiters > 0) {            // only signal a parked sender (skip the
                    pthread_cond_signal(&ch->not_full);  // syscall when producers are keeping up)
                }
                pthread_mutex_unlock(&ch->lock);
                Value some = alloc_instance(RT(vm), enum_id, some_tag, 1, 1);
                value_unbox(AS_STRUCT(some)->data, AEK_BOXED, v);
                vm->sp[-1] = some;                      // replace channel with Some(v)
                VM_NEXT();
#else
                if (ch->count == 0) {
                    if (ch->closed) {                  // drained + closed ⇒ None
                        Value none = alloc_instance(RT(vm), enum_id, none_tag, 1, 0);
                        vm->sp[-1] = none;
                        vm->current->block_channel = NULL;
                        VM_NEXT();
                    }
                    frame->ip = recv_op;               // retry OP_RECV (operands re-read on resume)
                    vm->current->block_channel = ch;
                    vm->current->block_is_send = 0;
                    return VM_YIELD;
                }
                Value v = ch->buffer[ch->head];
                ch->head = (ch->head + 1) % ch->capacity;
                ch->count--;
                Value some = alloc_instance(RT(vm), enum_id, some_tag, 1, 1);
                value_unbox(AS_STRUCT(some)->data, AEK_BOXED, v);
                vm->sp[-1] = some;                      // replace channel with Some(v)
                vm->current->block_channel = NULL;
                VM_NEXT();
#endif
            }
            VM_CASE(OP_TRY_RECV): {
                // Stack: [channel]. The NON-BLOCKING poll: Some(v) if a value is queued right now,
                // else None — never parks/yields. Lets an event loop check a channel each tick.
                int enum_id  = (int)operand_read(&frame->ip, OPK_IDX);
                int some_tag = (int)operand_read(&frame->ip, OPK_IDX);
                int none_tag = (int)operand_read(&frame->ip, OPK_IDX);
                ObjChannel *ch = AS_CHANNEL(vm->sp[-1]);
                int have = 0;
                Value v = INT_VAL(0);
#if EMBER_MN
                pthread_mutex_lock(&ch->lock);
                if (ch->count > 0) {
                    v = ch->buffer[ch->head];
                    ch->head = (ch->head + 1) % ch->capacity;
                    ch->count--;
                    have = 1;
                }
                Fiber *poll_tx = (have) ? ch_unpark(ch, 1) : NULL;   // a sender can now proceed
                pthread_mutex_unlock(&ch->lock);
                if (poll_tx != NULL) {
                    requeue(vm->sched, poll_tx);
                }
                vm->current->block_channel = NULL;                  // a poll never blocks
#elif EMBER_PARALLEL
                pthread_mutex_lock(&ch->lock);
                if (ch->count > 0) {
                    v = ch->buffer[ch->head];
                    ch->head = (ch->head + 1) % ch->capacity;
                    ch->count--;
                    have = 1;
                    if (ch->send_waiters > 0) {
                        pthread_cond_signal(&ch->not_full);
                    }
                }
                pthread_mutex_unlock(&ch->lock);
#else
                if (ch->count > 0) {
                    v = ch->buffer[ch->head];
                    ch->head = (ch->head + 1) % ch->capacity;
                    ch->count--;
                    have = 1;
                }
                vm->current->block_channel = NULL;     // a poll never blocks
#endif
                if (have) {
                    Value some = alloc_instance(RT(vm), enum_id, some_tag, 1, 1);
                    value_unbox(AS_STRUCT(some)->data, AEK_BOXED, v);
                    vm->sp[-1] = some;
                } else {
                    vm->sp[-1] = alloc_instance(RT(vm), enum_id, none_tag, 1, 0);
                }
                VM_NEXT();
            }
            VM_CASE(OP_CLOSE): {
                // Stack: [channel]. Mark it closed: queued values still drain, but
                // a subsequent recv on an empty channel returns None instead of
                // blocking. Idempotent. close yields unit (the statement pops it).
                ObjChannel *ch = AS_CHANNEL(vm->sp[-1]);
#if EMBER_MN
                // Close, then wake every parked fiber: a receiver re-runs and gets None; a sender
                // re-runs and errors (send-on-closed). Collect under the lock, requeue outside it.
                pthread_mutex_lock(&ch->lock);
                ch->closed = 1;
                Fiber *woken = NULL;
                for (Fiber *f = ch_unpark(ch, 0); f != NULL; f = ch_unpark(ch, 0)) {
                    f->qnext = woken;   // temp chain (qnext is unused until rq_push re-links it)
                    woken = f;
                }
                for (Fiber *f = ch_unpark(ch, 1); f != NULL; f = ch_unpark(ch, 1)) {
                    f->qnext = woken;
                    woken = f;
                }
                pthread_mutex_unlock(&ch->lock);
                while (woken != NULL) {
                    Fiber *nx = woken->qnext;
                    requeue(vm->sched, woken);
                    woken = nx;
                }
#elif EMBER_PARALLEL
                pthread_mutex_lock(&ch->lock);
                ch->closed = 1;
                pthread_cond_broadcast(&ch->not_empty);   // receivers drain, then get None
                pthread_cond_broadcast(&ch->not_full);    // senders re-check (no semantic change)
                pthread_mutex_unlock(&ch->lock);
#else
                ch->closed = 1;
#endif
                vm->sp[-1] = INT_VAL(0);
                VM_NEXT();
            }
            VM_CASE(OP_INCREF): {
                // A value read from an existing owner into a NEW owning slot. A refcounted shareable
                // value (string/enum/array/channel/closure) just records the extra owner. But a
                // value-STRUCT is a UNIQUE owner — not refcounted — so giving it two owners would
                // double-free it at drop (OFI-062): in an erased generic the codegen can't tell T is
                // a struct, so the fix lives here. Hand the new owner an independent CLONE instead —
                // copy the packed bytes and retain the struct's boxed leaves (so any heap fields are
                // shared with a proper refcount, while the shells are distinct).
                // own_into_slot: clone a unique-owner aggregate (value struct OR array) for the new
                // owner, retain a refcounted value, no-op a scalar (OFI-062/063).
                vm->sp[-1] = own_into_slot(RT(vm), vm->sp[-1]);
                VM_NEXT();
            }
            VM_CASE(OP_PICK): {
                // Push a copy of the value `n` slots below the top (n=0 is the top).
                // Used to re-fetch a kept owned-temp (evaluated earlier, sitting below
                // the call's arg region) into its argument position as a borrow alias —
                // the kept original is dropped after the call (OFI-027 multi-arg case).
                size_t n = operand_read(&frame->ip, OPK_IDX);
                if (!push(vm, vm->sp[-1 - (int)n])) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_DROP_UNDER): {
                // Reclaim the value just BELOW the top, keeping the top result. Used to
                // drop a fresh owned struct temporary that was passed by borrow to a
                // call/method (the temp sits under the call's result) — OFI-027. The
                // callee couldn't release it (a struct has no refcount), so the caller
                // does, here. drop_value frees a struct directly / releases a ref.
                Value result = vm->sp[-1];
                drop_value(RT(vm), vm->sp[-2]);
                vm->sp[-2] = result;
                vm->sp--;
                VM_NEXT();
            }
            VM_CASE(OP_RELEASE): {
                // Discard a fresh refcounted temporary on the stack top, releasing
                // its reference (e.g. a `recv` result that nothing binds).
                drop_value(RT(vm), vm->sp[-1]);
                vm->sp--;
                VM_NEXT();
            }
            VM_CASE(OP_DROP): {
                // Release a slot's owned value going out of scope: free a unique
                // struct (recursively), or drop one owner of a shared string. The
                // checker emits this for an owning struct/string binding; a slot
                // whose struct was moved out is nilled first, so this is then a
                // no-op. Operand: the local's slot. Does not touch the stack.
                size_t slot = operand_read(&frame->ip, OPK_IDX);
                drop_value(RT(vm), frame->slots[slot]);
                VM_NEXT();
            }
            VM_CASE(OP_NURSERY_BEGIN): {
#if EMBER_MN
                // M:N: a nursery is a heap struct linked onto THIS fiber's open-nursery stack (via
                // `cur_open` + the nursery's `enclosing`), so it survives the parent parking + resuming
                // on another worker (a VM-level depth stack would not). Spawns add children to it; the
                // closing brace parks the parent until they all finish.
                Nursery *nn = malloc(sizeof(Nursery));
                if (nn == NULL) {
                    fprintf(stderr, "emberc: out of memory opening a nursery\n");
                    exit(70);
                }
                nn->total = 0;
                nn->nwaiting = 0;
                nn->deadlocked = 0;
                nn->sealed = 0;
                nn->live = 0;
                nn->parent = NULL;
                nn->parent_parked = 0;
                nn->enclosing = vm->current->cur_open;
                nn->cancel = 0;
                nn->verdict = (int)VM_OK;
                nn->children = NULL;
                pthread_mutex_init(&nn->lock, NULL);
                vm->current->cur_open = nn;
                VM_NEXT();
#else
                // Open a structured task group. Spawns until NURSERY_END join here.
                if (vm->group_depth >= MAX_NURSERY_DEPTH) {
                    runtime_error("nurseries nested too deeply");
                    return VM_RUNTIME_ERROR;
                }
                int d = vm->group_depth;
                vm->group_sizes[d] = 0;
#if EMBER_PARALLEL
                // Allocate this nursery's run state up front. In the parallel model a
                // spawn starts its OS thread IMMEDIATELY (concurrent with the rest of the
                // body), so the threads, the per-task args the workers keep reading, and
                // the deadlock-detector block must outlive the body — they live here on
                // the heap until the join at NURSERY_END frees them.
                NurseryRun *run = malloc(sizeof(NurseryRun));
                if (run == NULL) {
                    fprintf(stderr, "emberc: out of memory opening a nursery\n");
                    exit(70);
                }
                run->grp.total      = 0;
                run->grp.nwaiting   = 0;
                run->grp.deadlocked = 0;
                run->grp.sealed     = 0;
                for (int i = 0; i < MAX_GROUP_FIBERS; i++) {
                    run->grp.active[i] = 0;
                }
                pthread_mutex_init(&run->grp.lock, NULL);
                vm->runs[d] = run;
#endif
                vm->group_depth = d + 1;
                VM_NEXT();
#endif
            }
            VM_CASE(OP_SPAWN): {
#if EMBER_MN
                // M:N: a spawn is CHEAP — allocate a fiber, copy in its args, init its own arena, and
                // push it onto the ready-queue (no pthread_create). It runs on whatever worker pops it.
                size_t func_index = operand_read(&frame->ip, OPK_IDX);
                int    argc        = (int)operand_read(&frame->ip, OPK_IDX);
                Nursery *nn = vm->current->cur_open;
                if (nn == NULL) {
                    runtime_error("spawn outside a nursery");
                    return VM_RUNTIME_ERROR;
                }
                Fiber *child = malloc(sizeof(Fiber));
                if (child == NULL) {
                    fprintf(stderr, "emberc: out of memory spawning a task\n");
                    exit(70);
                }
                for (int i = 0; i < argc; i++) {
                    child->stack[i] = vm->sp[-argc + i];
                }
                vm->sp -= argc;
                const Function *cfn = &vm->heap->prog->functions[func_index];
                child->frames[0].fn    = cfn;
                child->frames[0].ip    = cfn->chunk.code;
                child->frames[0].slots = child->stack;
                child->frame_count   = 1;
                child->sp            = child->stack + argc;
                child->block_channel = NULL;
                child->block_is_send = 0;
                child->qnext     = NULL;
                child->wait_next = NULL;
                child->fstate    = FS_READY;
                child->nursery   = nn;
                child->cur_open  = NULL;
                child->out       = NULL;
                child->pin_worker0 = 0;   // a spawned task may run on ANY worker (only main is pinned)
                child->rt.objects = NULL;
                for (int c = 0; c < POOL_CLASSES; c++) {
                    child->rt.pool[c] = NULL;
                }
                child->rt.structs      = vm->heap->prog->structs;
                child->rt.struct_count = vm->heap->prog->struct_count;
                child->rt.invoke       = NULL;   // OFI-122: VM resource-drop invoke wired in a follow-up
                pthread_mutex_lock(&nn->lock);
                child->sib_next = nn->children;   // prepend to the group's child list (no cap)
                nn->children = child;
                nn->live++;
                nn->total++;
                pthread_mutex_unlock(&nn->lock);
                pthread_mutex_lock(&vm->sched->lock);
                vm->sched->live++;          // a new fiber exists globally
                pthread_mutex_unlock(&vm->sched->lock);
                rq_push(vm->sched, child);  // wakes an idle worker
                VM_NEXT();
#else
                // Create a fiber for `f(args)` and add it to the innermost group.
                // Args were pushed onto this fiber's stack; copy them in as the
                // child's locals 0..argc-1.
                size_t func_index = operand_read(&frame->ip, OPK_IDX);
                int    argc        = (int)operand_read(&frame->ip, OPK_IDX);
                int g = vm->group_depth - 1;
                if (g < 0 || vm->group_sizes[g] >= MAX_GROUP_FIBERS) {
                    runtime_error("too many spawned tasks in one nursery");
                    return VM_RUNTIME_ERROR;
                }
                Fiber *child = malloc(sizeof(Fiber));
                if (child == NULL) {
                    fprintf(stderr, "emberc: out of memory spawning a task\n");
                    exit(70);
                }
                for (int i = 0; i < argc; i++) {
                    child->stack[i] = vm->sp[-argc + i];
                }
                vm->sp -= argc;
                const Function *fn = &vm->heap->prog->functions[func_index];
                child->frames[0].fn    = fn;
                child->frames[0].ip    = fn->chunk.code;
                child->frames[0].slots = child->stack;
                child->frame_count = 1;
                child->sp          = child->stack + argc;
                child->block_channel = NULL;
                int slot = vm->group_sizes[g];
                vm->groups[g][slot] = child;
                vm->group_sizes[g]  = slot + 1;
#if EMBER_PARALLEL
                // Spawn-at-spawn-time: launch this task's OS thread NOW, so it runs
                // concurrently with the rest of the nursery body (e.g. an event loop that
                // polls it with try_recv). The closing brace (NURSERY_END) joins it. The
                // deadlock detector is gated on the nursery being SEALED, so `total` growing
                // here mid-body never triggers a false positive while the body can still
                // unblock a parked task.
                NurseryRun *run = vm->runs[g];
                pthread_mutex_lock(&run->grp.lock);
                run->grp.total = slot + 1;
                pthread_mutex_unlock(&run->grp.lock);
                run->args[slot].heap    = vm->heap;
                run->args[slot].fiber   = child;
                run->args[slot].nursery = &run->grp;
                run->args[slot].slot    = slot;
                run->args[slot].tracer  = tracer;
                run->args[slot].result  = VM_OK;
                if (pthread_create(&run->threads[slot], NULL,
                                   worker_entry, &run->args[slot]) == 0) {
                    run->joinable[slot] = 1;
                } else {
                    // Out of OS threads: run this task inline now so none is lost. Degraded
                    // (it blocks the body until the task finishes), but correctness holds.
                    run->joinable[slot] = 0;
                    Nursery *saved_n    = vm->nursery;
                    int      saved_slot = vm->nursery_slot;
                    vm->nursery         = &run->grp;
                    vm->nursery_slot    = slot;
                    run->args[slot].result = run_child(vm, child, tracer);
                    vm->nursery         = saved_n;
                    vm->nursery_slot    = saved_slot;
                }
#endif
                VM_NEXT();
#endif
            }
            VM_CASE(OP_NURSERY_END): {
#if EMBER_MN
                // M:N: SEAL the group; if children are still live, PARK the parent (rewind so it
                // re-runs this op when the last child wakes it). When live==0, finalize: read the
                // verdict, pop this nursery off the fiber's open stack, free it, and propagate any
                // error. live-- (in finish_child) and this seal+read are both under n->lock, so the
                // parent always observes a consistent count and is the sole owner that frees `n`.
                Nursery *nn = vm->current->cur_open;
                pthread_mutex_lock(&nn->lock);
                nn->sealed = 1;
                if (nn->live > 0) {
                    nn->parent = vm->current;
                    nn->parent_parked = 1;
                    __atomic_store_n(&vm->current->fstate, FS_PARKED, __ATOMIC_RELEASE);
                    pthread_mutex_unlock(&nn->lock);
                    frame->ip--;                 // re-run OP_NURSERY_END (operandless) on resume
                    return VM_YIELD;
                }
                pthread_mutex_unlock(&nn->lock);
                // All children are DONE (live==0) → the parent reclaims them now (deferred from
                // finish_child so the cancel sweep never touched freed memory), pops the nursery off
                // this fiber's open-stack, frees it, and propagates the first error (if any).
                VMResult verdict = (VMResult)nn->verdict;
                Fiber *c = nn->children;
                while (c != NULL) {
                    Fiber *nx = c->sib_next;
                    retire_fiber(vm, c);
                    c = nx;
                }
                vm->current->cur_open = nn->enclosing;
                pthread_mutex_destroy(&nn->lock);
                free(nn);
                if (verdict != VM_OK) {
                    return verdict;
                }
                VM_NEXT();
#else
                // Keep this nursery's slot OPEN while its tasks run, and pop it only
                // once they have all finished (below). The serial scheduler runs the
                // tasks on this same VM, so a task that opens a NESTED nursery must
                // stack onto a deeper slot — popping here first would make it reuse
                // slot g and clobber the group array this loop is still iterating.
                int g = vm->group_depth - 1;
                int n = vm->group_sizes[g];
                Fiber **fibers = vm->groups[g];
#if EMBER_PARALLEL
                // Parallel: every task's OS thread was already started by OP_SPAWN and has
                // been running concurrently with this body. Now SEAL the group (no further
                // tasks can join) and JOIN them all. Sealing first lets the deadlock detector
                // finally rule: while the body ran we deferred the verdict (the body could
                // still unblock a parked task), but once it is done an all-parked group with
                // no ready channel is a true deadlock. Re-check it here because the workers
                // that parked before the seal are now asleep on condvars and will not re-run
                // the in-park check themselves — this is the seal-time companion to it.
                NurseryRun *run = vm->runs[g];
                pthread_mutex_lock(&run->grp.lock);
                run->grp.sealed = 1;
                if (run->grp.total > 0 && run->grp.nwaiting == run->grp.total) {
                    int any_ready = 0;
                    for (int i = 0; i < run->grp.total && !any_ready; i++) {
                        if (!run->grp.active[i]) {
                            continue;
                        }
                        ObjChannel *c = run->grp.waits_on[i];
                        any_ready = run->grp.is_send[i] ? (c->count < c->capacity)
                                                        : (c->count > 0 || c->closed);
                    }
                    if (!any_ready) {
                        __atomic_store_n(&run->grp.deadlocked, 1, __ATOMIC_SEQ_CST);
                        for (int i = 0; i < run->grp.total; i++) {
                            if (run->grp.active[i]) {
                                if (run->grp.is_send[i]) {
                                    pthread_cond_broadcast(&run->grp.waits_on[i]->not_full);
                                } else {
                                    pthread_cond_broadcast(&run->grp.waits_on[i]->not_empty);
                                }
                            }
                        }
                        runtime_error("deadlock: every task in the nursery is blocked");
                    }
                }
                pthread_mutex_unlock(&run->grp.lock);
                VMResult err = VM_OK;
                for (int i = 0; i < n; i++) {
                    if (run->joinable[i]) {
                        pthread_join(run->threads[i], NULL);
                    }
                    if (run->args[i].result == VM_RUNTIME_ERROR) {
                        err = VM_RUNTIME_ERROR;
                    }
                }
                pthread_mutex_destroy(&run->grp.lock);
                free(run);
                vm->runs[g] = NULL;
                vm->group_depth = g;     // all tasks done — now pop this nursery
                for (int i = 0; i < n; i++) {
                    free(fibers[i]);
                }
                if (err != VM_OK) {
                    return err;
                }
                VM_NEXT();
#else
                // Cooperatively run the innermost group's tasks until all finish.
                // Each pass runs every *runnable* fiber (not blocked, or whose
                // channel is now ready) until it blocks again or completes. A pass
                // with no runnable fiber while tasks remain is a deadlock.
                int done[MAX_GROUP_FIBERS] = {0};
                int remaining = n;
                VMResult err = VM_OK;
                while (remaining > 0) {
                    int progressed = 0;
                    for (int i = 0; i < n && err == VM_OK; i++) {
                        if (done[i]) {
                            continue;
                        }
                        Fiber *c = fibers[i];
                        if (c->block_channel != NULL) {   // still blocked?
                            ObjChannel *ch = c->block_channel;
                            // A recv also unblocks on close — it will receive None.
                            int ready = c->block_is_send
                                            ? ch->count < ch->capacity
                                            : (ch->count > 0 || ch->closed);
                            if (!ready) {
                                continue;
                            }
                        }
                        VMResult r = run_child(vm, c, tracer);
                        progressed = 1;
                        if (r == VM_OK) {
                            done[i] = 1;
                            remaining--;
                        } else if (r == VM_RUNTIME_ERROR) {
                            err = VM_RUNTIME_ERROR;
                        }
                        // VM_YIELD: c blocked (block_channel set); revisit it later.
                    }
                    if (err != VM_OK) {
                        break;
                    }
                    if (!progressed) {
                        runtime_error("deadlock: every task in the nursery is blocked");
                        err = VM_RUNTIME_ERROR;
                        break;
                    }
                }
                vm->group_depth = g;     // all tasks done — now pop this nursery
                for (int i = 0; i < n; i++) {
                    free(fibers[i]);
                }
                if (err != VM_OK) {
                    return err;
                }
                VM_NEXT();
#endif
#endif
            }
            VM_CASE(OP_RETURN_STRUCT): {
                // Return a MULTI-SLOT struct value (value-types 3b.4b): its N field slots
                // sit on top of the returning frame. Move them down onto the frame's base
                // (where the args were), so the struct value occupies the call's slots in
                // the caller — the mirror of OP_RETURN moving one value. The frame's owning
                // locals were already dropped by the codegen-emitted OP_DROPs; an all-scalar
                // struct holds no heap refs, so the slots copy by value.
                int n = (int)operand_read(&frame->ip, OPK_IDX);
                vm->frame_count--;
                if (vm->frame_count <= vm->reentry_floor) {
                    // Top level: main returns int, a spawned task discards its result —
                    // drop the (ref-free) slots and hand back a unit.
                    vm->sp -= n;
                    *out = INT_VAL(0);
                    return VM_OK;
                }
                Value *dst = frame->slots;
                Value *src = vm->sp - n;
                for (int i = 0; i < n; i++) {
                    dst[i] = src[i];
                }
                vm->sp = frame->slots + n;
                frame = &vm->frames[vm->frame_count - 1];
                VM_NEXT();
            }
            VM_CASE(OP_RETURN): {
                Value result = pop(vm);
                vm->frame_count--;
                if (vm->frame_count <= vm->reentry_floor) {
                    *out = result;
                    return VM_OK;
                }
                vm->sp = frame->slots;
                frame = &vm->frames[vm->frame_count - 1];
                if (!push(vm, result)) {
                    return VM_RUNTIME_ERROR;
                }
                VM_NEXT();
            }
            VM_CASE(OP_ROUTE_HOP): {
                // Record a `?`-propagation hop (OFI-108): the Err is being returned early from this
                // frame by `?`. The buffer was cleared at the last CALL (a call can't happen while a
                // `?` chain unwinds, so any earlier — necessarily handled — chain is gone), so the
                // buffer holds exactly the current chain: append, newest-first by construction since
                // hops unwind deepest→shallowest. Never touches the stack, so it can't perturb the
                // value being returned or the early-return drops that follow. Release-elided.
                if (vm->route_hop_count < FAULT_MAX_HOPS) {
                    FaultHop *h = &vm->route_hops[vm->route_hop_count++];
                    h->fn   = frame->fn->name;
                    h->line = fault_line(frame);
                }
                VM_NEXT();
            }
            VM_CASE(OP__COUNT):
                runtime_error("corrupt bytecode: invalid opcode");
                return VM_RUNTIME_ERROR;
#if !EMBER_THREADED
        }   // switch
    }       // for (;;)
#endif
#undef VM_CASE
#undef VM_NEXT
}





#undef ARITH
#undef COMPARE




// run_child runs a spawned fiber to completion by repointing the active view at
// it, invoking the interpreter loop, then restoring the caller's view. (Step 2 of
// the green-thread runtime: tasks run to completion — cooperative yielding on
// channel operations comes with channels.) Heap objects the task allocates stay
// on the shared object list and are freed at the program's end. (M:N uses its own
// run_fiber_once on a worker pool — run_child serves only the serial + 1:1 schedulers.)
#if !EMBER_MN
static VMResult run_child(VM *vm, Fiber *child, const Tracer *tracer) {
    Fiber     *saved_cur    = vm->current;
    Value     *saved_stack  = vm->stack;
    Value     *saved_sp     = vm->sp;
    CallFrame *saved_frames = vm->frames;
    int        saved_fc     = vm->frame_count;

    vm->current     = child;
    vm->stack       = child->stack;
    vm->frames      = child->frames;
    vm->sp          = child->sp;
    vm->frame_count = child->frame_count;

    Value throwaway = INT_VAL(0);
    VMResult r = run(vm, &throwaway, tracer);
    child->sp          = vm->sp;            // save progress so a yield can resume
    child->frame_count = vm->frame_count;

    vm->current     = saved_cur;
    vm->stack       = saved_stack;
    vm->sp          = saved_sp;
    vm->frames      = saved_frames;
    vm->frame_count = saved_fc;
    return r;
}
#endif





int vm_exited(const VM *vm, int *code) {
    if (vm->exit_requested) {
        *code = (int)vm->exit_code;
        return 1;
    }
    return 0;
}




// vm_route copies the recorded `?`-propagation route (OFI-108) into `route` (capacity
// FAULT_MAX_HOPS), setting *count. The driver attaches it to an unhandled-Err-at-main Fault,
// where the synchronous call stack is useless because the propagating frames have returned.
void vm_route(const VM *vm, FaultHop *route, int *count) {
    int n = vm->route_hop_count < FAULT_MAX_HOPS ? vm->route_hop_count : FAULT_MAX_HOPS;
    for (int i = 0; i < n; i++) {
        route[i] = vm->route_hops[i];
    }
    *count = n;
}


// vm_invoke_drop runs an Ember function by table index RE-ENTRANTLY from inside the VM — it is the
// `EmberRt.invoke` the runtime's drop_value calls to run a `resource`'s user `drop(self)` during
// teardown (OFI-122). It pushes a fresh frame for `fn_index` (a `drop` takes exactly `self`) on TOP of
// the live call stack, sets `reentry_floor` so the interpreter returns when THAT frame returns (not the
// whole program), runs it, then restores the caller's stack/frame view. The outer frame is untouched
// (the drop runs in its own frame above it), so the suspended OP_DROP resumes cleanly. Under the M:N
// build the rt lives in a fiber (not the VM), so the container_of is invalid — resource drop is
// deferred there for now (Phase 1); the serial + 1:1-parallel VMs embed the rt in the VM.
static Value vm_invoke_drop(EmberRt *ctx, int fn_index, Value *args) {
#if EMBER_MN
    (void)ctx; (void)fn_index; (void)args;
    return INT_VAL(0);
#else
    VM *vm = (VM *)((char *)ctx - offsetof(VM, rt));
    int    saved_floor = vm->reentry_floor;
    Value *saved_sp    = vm->sp;
    int    saved_fc    = vm->frame_count;
    const Function *fn = &vm->heap->prog->functions[fn_index];
    Value *base = vm->sp;
    base[0]     = args[0];             // self (a resource `drop` is always exactly 1-arg)
    vm->sp      = base + 1;
    CallFrame *frame = &vm->frames[vm->frame_count++];
    frame->fn    = fn;
    frame->ip    = fn->chunk.code;
    frame->slots = base;
    vm->reentry_floor = saved_fc;      // run() returns when the drop frame pops back to here
    Value out = INT_VAL(0);
    run(vm, &out, NULL);
    vm->reentry_floor = saved_floor;
    vm->sp            = saved_sp;
    vm->frame_count   = saved_fc;
    return out;
#endif
}


VM *vm_create(const CompiledProgram *prog) {
    VM *vm = malloc(sizeof(VM));
    Heap *heap = malloc(sizeof(Heap));
    Fiber *main_fiber = malloc(sizeof(Fiber));
    if (vm == NULL || heap == NULL || main_fiber == NULL) {
        fprintf(stderr, "emberc: out of memory creating the VM\n");
        exit(70);
    }
    srand((unsigned)time(NULL));   // seed random() for this run
    heap->prog      = prog;
    heap->graveyard = NULL;
    for (int c = 0; c < POOL_CLASSES; c++) {
        heap->gpool[c] = NULL;
    }
#if EMBER_PARALLEL
    pthread_mutex_init(&heap->lock, NULL);
#endif
    vm->heap        = heap;
#if EMBER_MN
    // M:N: the arena lives in the main fiber; point active_rt at it BEFORE the RT(vm) init below.
    vm->active_rt        = &main_fiber->rt;
    vm->sched            = NULL;          // installed by vm_run
    main_fiber->qnext    = NULL;
    main_fiber->wait_next = NULL;
    main_fiber->fstate   = FS_RUNNING;
    main_fiber->nursery  = NULL;          // the main fiber is not a child of any group
    main_fiber->cur_open = NULL;
    main_fiber->out      = NULL;
    main_fiber->block_is_send = 0;
    main_fiber->pin_worker0 = 0;   // vm_run sets it to 1 for the M:N run (the GL-context pin)
#endif
    RT(vm)->objects     = NULL;          // the main thread's own private arena
    for (int c = 0; c < POOL_CLASSES; c++) {
        RT(vm)->pool[c] = NULL;
    }
    RT(vm)->structs      = prog->structs;   // the layout table the runtime reads (ctx->structs)
    RT(vm)->struct_count = prog->struct_count;
    RT(vm)->invoke       = vm_invoke_drop;   // OFI-122: run a resource's drop(self) on teardown
    vm->reentry_floor    = 0;                 // run() returns at frame_count 0 unless a re-entrant drop raises it
    vm->current     = main_fiber;
    main_fiber->block_channel = NULL;
    vm->stack       = main_fiber->stack;     // point the active view at the fiber
    vm->sp          = main_fiber->stack;
    vm->frames      = main_fiber->frames;
    vm->frame_count = 0;
    vm->group_depth = 0;
    vm->check_mode  = 0;
    vm->check_msg   = NULL;
    vm->route_hop_count  = 0;
    vm->nondet_mode     = 0;
    vm->nondet_log      = NULL;
    vm->nondet_count    = 0;
    vm->nondet_cap      = 0;
    vm->nondet_pos      = 0;
    vm->nondet_diverged = 0;
    vm->capturing       = 0;
    vm->cap_buf         = NULL;
    vm->cap_len         = 0;
    vm->cap_cap         = 0;
    vm->exit_requested  = 0;
    vm->exit_code       = 0;
#if EMBER_PARALLEL && !EMBER_MN
    vm->nursery      = NULL;         // top level: no enclosing nursery (1:1 deadlock detector)
    vm->nursery_slot = 0;
#endif

    CallFrame *frame = &vm->frames[vm->frame_count++];
    frame->fn    = &prog->functions[prog->main_index];
    frame->ip    = frame->fn->chunk.code;
    frame->slots = vm->stack;
    return vm;
}





#if EMBER_MN
// M:N driver: stand up the scheduler, make the calling thread worker 0, spawn M-1 helper workers
// (each its own VM sharing the heap + scheduler), push the main fiber, and run the pool until the
// program ends (live==0), deadlocks, errors, or calls exit(). The main fiber's return value lands in
// `out` via main_fiber->out. A top-level channel block is no longer an instant deadlock — main just
// parks and a child can wake it; "deadlock" is the global all-idle verdict.
VMResult vm_run(VM *vm, Value *out, const Tracer *tracer) {
    Scheduler sched;
    pthread_mutex_init(&sched.lock, NULL);
    pthread_cond_init(&sched.nonempty, NULL);
    sched.head = sched.tail = NULL;
    sched.pinned = NULL;            // the worker-0-only slot for the main/GL fiber (OFI-138/089)
    long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    int M = (ncpu > 1) ? (int)ncpu : 1;
    if (M > MAX_WORKERS) {
        M = MAX_WORKERS;
    }
    sched.nworkers = M;
    sched.nidle = 0;
    sched.nready = 0;
    sched.live = 1;                 // the main fiber
    sched.shutdown = 0;
    sched.halting = 0;
    sched.reported = 0;
    sched.global_error = VM_OK;
    sched.exit_req = 0;
    sched.exit_code = 0;
    vm->sched = &sched;
    // Sync the main fiber's SAVED exec state from vm_create's initial setup (it filled the live view
    // vm->sp/frame_count but not the fiber's saved copies, which run_fiber_once reads to resume it).
    vm->current->sp          = vm->sp;
    vm->current->frame_count = vm->frame_count;
    vm->current->out    = out;      // capture main's return value
    vm->current->fstate = FS_RUNNING;
    vm->current->pin_worker0 = 1;   // the main fiber resumes only on worker 0 = this GL-context thread

    // Start the M-1 helper workers FIRST (each its own VM sharing the heap + scheduler); they drain
    // the ready-queue, so a fiber main spawns runs immediately.
    pthread_t threads[MAX_WORKERS];
    VM       *workers[MAX_WORKERS];
    MNWorkerArg args[MAX_WORKERS];
    for (int i = 1; i < M; i++) {
        workers[i] = NULL;
        VM *w = malloc(sizeof(VM));
        if (w == NULL) {
            continue;
        }
        *w = *vm;                   // share heap + sched + modes; the exec view is repointed per fiber
        w->active_rt = NULL;
        args[i].w = w;
        args[i].tracer = tracer;
        if (pthread_create(&threads[i], NULL, mn_worker_entry, &args[i]) == 0) {
            workers[i] = w;
        } else {
            free(w);
        }
    }

    // The calling thread (= worker 0 = the process MAIN OS thread) runs the MAIN fiber DIRECTLY, not
    // via the ready-queue. This is load-bearing for GUI apps: raylib/GLFW/Cocoa require their calls on
    // the main thread, and the render loop is the main fiber — running it on a helper pthread traps.
    // The render loop usually never parks (it polls with try_recv inside the nursery body) so it stays
    // here for the whole run; but if main DOES park (e.g. a nursery join at window-close while a fetch
    // is in flight), it is now PINNED to worker 0 — rq_push routes it to the dedicated slot and only
    // this thread resumes it, so the GL teardown can't land on a helper thread (OFI-138/089 closed).
    {
        VMResult mr = run_fiber_once(vm, vm->current, tracer);
        if (vm->exit_requested) {
            pthread_mutex_lock(&sched.lock);
            if (!sched.exit_req) {
                sched.exit_req  = 1;
                sched.exit_code = vm->exit_code;
            }
            sched.halting  = 1;
            sched.shutdown = 1;
            pthread_cond_broadcast(&sched.nonempty);
            pthread_mutex_unlock(&sched.lock);
            finish_child(vm, vm->current, VM_OK);
        } else if (mr != VM_YIELD) {
            finish_child(vm, vm->current, mr);   // VM_OK / error / cancelled
        }
        // VM_YIELD: main parked itself (registered on a channel/nursery); a child will requeue it.
    }
    scheduler_worker_main(vm, tracer, 1);   // worker 0 then helps drain the pool (+ its pinned slot)
    for (int i = 1; i < M; i++) {
        if (workers[i] != NULL) {
            pthread_join(threads[i], NULL);
            free(workers[i]);
        }
    }
    pthread_cond_destroy(&sched.nonempty);
    pthread_mutex_destroy(&sched.lock);
    vm->sched = NULL;
    if (sched.exit_req) {
        vm->exit_requested = 1;
        vm->exit_code = sched.exit_code;
        return VM_OK;
    }
    if (sched.global_error != VM_OK) {
        return sched.global_error;
    }
    return VM_OK;
}
#else
VMResult vm_run(VM *vm, Value *out, const Tracer *tracer) {
    VMResult r = run(vm, out, tracer);
    if (r == VM_YIELD) {   // main blocked on a channel with no task to unblock it
        runtime_error("deadlock: the main task blocked on a channel");
        return VM_RUNTIME_ERROR;
    }
    return r;
}
#endif


// vm_replay implements the verification loop's record-replay brick (§5j). It runs `prog` twice:
// first RECORDING every nondeterministic scalar (`random`, the clock) and buffering output, then
// REPLAYING those exact values and buffering output again. If the two runs agree byte-for-byte
// (same result, same output, every recorded value consumed, no divergence), the program is
// deterministic modulo its captured nondeterminism — so a failing run can always be reproduced.
// Returns 0 when the replay reproduces the recording, 1 otherwise. Two runs are used so the proof
// is self-contained: no tape file to manage, and the verdict is stable across invocations even
// though the underlying random/clock values differ each time.
int vm_replay(const CompiledProgram *prog, const Tracer *tracer) {
    (void)tracer;
    VM *rec = vm_create(prog);
    rec->nondet_mode = 1;
    rec->capturing   = 1;
    Value out1;
    VMResult r1 = vm_run(rec, &out1, NULL);
    long long ret1 = IS_INT(out1) ? AS_INT(out1) : 0;

    VM *rep = vm_create(prog);
    rep->nondet_mode  = 2;
    rep->nondet_log   = rec->nondet_log;     // borrow the recording (detached before destroy)
    rep->nondet_count = rec->nondet_count;
    rep->capturing    = 1;
    Value out2;
    VMResult r2 = vm_run(rep, &out2, NULL);
    long long ret2 = IS_INT(out2) ? AS_INT(out2) : 0;

    int n_random = 0, n_clock = 0, n_line = 0, n_file = 0, n_ffi = 0;
    for (int i = 0; i < rec->nondet_count; i++) {
        const char *s = rec->nondet_log[i].src;
        if      (s == NONDET_RANDOM)    { n_random++; }
        else if (s == NONDET_CLOCK)     { n_clock++; }
        else if (s == NONDET_READ_LINE) { n_line++; }
        else if (s == NONDET_READ_FILE) { n_file++; }
        else if (s == NONDET_FFI)       { n_ffi++; }
    }

    int ok = r1 == r2 && r1 == VM_OK && !rep->nondet_diverged && ret1 == ret2 &&
             rep->nondet_pos == rec->nondet_count && rec->cap_len == rep->cap_len &&
             (rec->cap_len == 0 || memcmp(rec->cap_buf, rep->cap_buf, rec->cap_len) == 0);

    if (ok) {
        printf("replay: deterministic — %d nondeterministic event(s) recorded "
               "(%d random, %d clock, %d read_line, %d read_file, %d ffi); both runs identical\n",
               rec->nondet_count, n_random, n_clock, n_line, n_file, n_ffi);
        printf("{\"event\":\"replay\",\"status\":\"deterministic\",\"events\":%d,\"random\":%d,"
               "\"clock\":%d,\"read_line\":%d,\"read_file\":%d,\"ffi\":%d}\n",
               rec->nondet_count, n_random, n_clock, n_line, n_file, n_ffi);
    } else {
        printf("replay: DIVERGED — the replay did not reproduce the recorded run "
               "(recorded %d, consumed %d)\n", rec->nondet_count, rep->nondet_pos);
        printf("{\"event\":\"replay\",\"status\":\"diverged\",\"events\":%d,\"consumed\":%d}\n",
               rec->nondet_count, rep->nondet_pos);
    }

    rep->nondet_log   = NULL;    // borrowed from rec — let rec free it once
    rep->nondet_count = 0;
    vm_destroy(rep);
    vm_destroy(rec);
    return ok ? 0 : 1;
}


// --- Property-based contract checking (§5j, `--check`) ------------------------------------
// A reproducible (fixed-seed, platform-independent) generator + a per-trial invoker that runs a
// fuzzable function on random inputs in check mode, so a contract violation is caught and
// classified instead of aborting the tool. The counterexamples it reports are the agent
// correctness loop made concrete: write a contract, get a falsifying input back.

#define CHECK_TRIALS      300    // inputs generated per function
#define CHECK_MAX_REJECTS 8000   // give up satisfying a `requires` after this many rejections

static uint64_t g_check_rng;     // xorshift64 state (seeded fixed for reproducibility)

static uint64_t check_rand(void) {
    uint64_t x = g_check_rng;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    g_check_rng = x;
    return x;
}

// gen_scalar makes a random argument for a parameter of fuzz kind `k`, mixing boundary values
// (0, 1, -1) with bounded random values to hit edges without provoking spurious overflow traps.
static Value gen_scalar(char k) {
    if (k == 'b') {
        return INT_VAL((int64_t)(check_rand() & 1));
    }
    if (k == 'f') {
        switch (check_rand() % 8) {
            case 0: return FLOAT_VAL(0.0);
            case 1: return FLOAT_VAL(1.0);
            case 2: return FLOAT_VAL(-1.0);
            default: return FLOAT_VAL((double)((int64_t)(check_rand() % 2000001) - 1000000)
                                      / 1000.0);
        }
    }
    switch (check_rand() % 8) {        // 'i'
        case 0: return INT_VAL(0);
        case 1: return INT_VAL(1);
        case 2: return INT_VAL(-1);
        default: return INT_VAL((int64_t)(check_rand() % 20001) - 10000);
    }
}

// gen_array makes a random immutable-borrow array argument: a small random length (0..8) of
// elements of fuzz kind `elem` packed at ArrayElemKind `aek`. The ObjArray is registered on the
// VM's object list (freed at vm_destroy), so trials accumulate a bounded amount of garbage.
static Value gen_array(VM *vm, char elem, unsigned char aek) {
    size_t len = (size_t)(check_rand() % 9);
    Value  arr = alloc_array(RT(vm), len, aek);
    ObjArray *a = AS_ARRAY(arr);
    for (size_t i = 0; i < len; i++) {
        array_unbox(a, i, gen_scalar(elem));
    }
    return arr;
}

// run_one_trial invokes function `fi` with `args` in check mode and returns the result. On
// VM_RUNTIME_ERROR, vm->check_msg holds the contract message (NULL ⇒ a non-contract crash).
static VMResult run_one_trial(VM *vm, int fi, const Value *args, int argc) {
    const Function *fn = &vm->heap->prog->functions[fi];
    vm->frame_count = 0;
    vm->group_depth = 0;
    for (int i = 0; i < argc; i++) {
        vm->stack[i] = args[i];
    }
    vm->sp = vm->stack + argc;
    CallFrame *frame = &vm->frames[vm->frame_count++];
    frame->fn    = fn;
    frame->ip    = fn->chunk.code;
    frame->slots = vm->stack;
    vm->check_msg = NULL;
    Value out;
    return run(vm, &out, NULL);
}

// trial_fails reports whether `args` is a real counterexample for `fi`: the function violated a
// postcondition/assert or crashed — NOT a `requires` rejection (out-of-domain) or a pass.
static int trial_fails(VM *vm, int fi, const Value *args, int argc) {
    VMResult r = run_one_trial(vm, fi, args, argc);
    if (r != VM_RUNTIME_ERROR) {
        return 0;
    }
    if (vm->check_msg != NULL && strncmp(vm->check_msg, "precondition", 12) == 0) {
        return 0;   // generated input is out of the function's domain
    }
    return 1;
}

// shrink greedily minimises a counterexample toward simpler values (0, then halving toward 0;
// false for bools) while it still fails, so the reported input is small and legible — the form
// an agent or human can reason about. Deterministic (no RNG): the minimal repro is reproducible.
// shrink_elem minimises one packed array element `e` of `a` (fuzz kind `ek`) toward 0/false while
// the counterexample still fails. Returns 1 if it found a smaller value.
static int shrink_elem(VM *vm, int fi, Value *args, int argc, ObjArray *a, size_t e, char ek) {
    Value cur = array_box(a, e);
    if (ek == 'f') {
        if (AS_FLOAT(cur) == 0.0) { return 0; }
        array_unbox(a, e, FLOAT_VAL(0.0));
        if (trial_fails(vm, fi, args, argc)) { return 1; }
        array_unbox(a, e, FLOAT_VAL(AS_FLOAT(cur) / 2.0));
        if (trial_fails(vm, fi, args, argc)) { return 1; }
        array_unbox(a, e, cur);
        return 0;
    }
    if (ek == 'b') {
        if (AS_INT(cur) == 0) { return 0; }
        array_unbox(a, e, INT_VAL(0));
        if (trial_fails(vm, fi, args, argc)) { return 1; }
        array_unbox(a, e, cur);
        return 0;
    }
    if (AS_INT(cur) == 0) { return 0; }
    array_unbox(a, e, INT_VAL(0));
    if (trial_fails(vm, fi, args, argc)) { return 1; }
    array_unbox(a, e, INT_VAL(AS_INT(cur) / 2));
    if (trial_fails(vm, fi, args, argc)) { return 1; }
    array_unbox(a, e, cur);
    return 0;
}

// shrink greedily minimises a counterexample toward simpler values (0, then halving toward 0;
// false for bools; shorter arrays with simpler elements) while it still fails, so the reported
// input is small and legible. Deterministic (no RNG): the minimal repro is reproducible.
static void shrink(VM *vm, int fi, Value *args, int argc, const Function *fn) {
    int improved = 1;
    for (int pass = 0; improved && pass < 64; pass++) {
        improved = 0;
        for (int i = 0; i < argc; i++) {
            char k = fn->leaf_kind[i];
            if (k == 'a') {
                ObjArray *a    = AS_ARRAY(args[i]);
                uint8_t   esz  = a->elem_size;
                unsigned char *d = (unsigned char *)a->data;
                int removed = 1;
                while (removed) {     // drop ANY element whose removal preserves the failure
                    removed = 0;
                    for (size_t e = 0; e < a->length; ) {
                        unsigned char tmp[16];
                        memcpy(tmp, d + e * esz, esz);
                        memmove(d + e * esz, d + (e + 1) * esz, (a->length - 1 - e) * esz);
                        a->length--;
                        if (trial_fails(vm, fi, args, argc)) {
                            improved = 1;
                            removed  = 1;     // index e now holds the next element — rescan it
                        } else {
                            memmove(d + (e + 1) * esz, d + e * esz, (a->length - e) * esz);
                            memcpy(d + e * esz, tmp, esz);
                            a->length++;
                            e++;
                        }
                    }
                }
                for (size_t e = 0; e < a->length; e++) {   // then simplify each survivor
                    if (shrink_elem(vm, fi, args, argc, a, e, fn->leaf_elem[i])) { improved = 1; }
                }
                continue;
            }
            Value save = args[i];
            if (k == 'b') {
                if (AS_INT(save) != 0) {
                    args[i] = INT_VAL(0);
                    if (trial_fails(vm, fi, args, argc)) { improved = 1; } else { args[i] = save; }
                }
            } else if (k == 'f') {
                double cur = AS_FLOAT(save);
                if (cur != 0.0) {
                    args[i] = FLOAT_VAL(0.0);
                    if (trial_fails(vm, fi, args, argc)) { improved = 1; continue; }
                    args[i] = FLOAT_VAL(cur / 2.0);
                    if (trial_fails(vm, fi, args, argc)) { improved = 1; } else { args[i] = save; }
                }
            } else {   // 'i'
                int64_t cur = AS_INT(save);
                if (cur != 0) {
                    args[i] = INT_VAL(0);
                    if (trial_fails(vm, fi, args, argc)) { improved = 1; continue; }
                    args[i] = INT_VAL(cur / 2);
                    if (trial_fails(vm, fi, args, argc)) { improved = 1; } else { args[i] = save; }
                }
            }
        }
    }
}

// format_leaf renders one generated scalar leaf according to its fuzz kind.
static int format_leaf(char *buf, size_t cap, char k, Value v) {
    if (k == 'f') {
        return snprintf(buf, cap, "%g", AS_FLOAT(v));
    }
    if (k == 'b') {
        return snprintf(buf, cap, "%s", AS_INT(v) ? "true" : "false");
    }
    return snprintf(buf, cap, "%lld", (long long)AS_INT(v));
}

// format_array renders a generated array argument as `[e0, e1, …]`.
static int format_array(char *buf, size_t cap, char elem, Value v) {
    const ObjArray *a = AS_ARRAY(v);
    int off = snprintf(buf, cap, "[");
    for (size_t i = 0; i < a->length && (size_t)off < cap; i++) {
        if (i > 0) {
            off += snprintf(buf + off, cap - (size_t)off, ", ");
        }
        off += format_leaf(buf + off, cap - (size_t)off, elem, array_box(a, i));
    }
    off += snprintf(buf + off, cap - (size_t)off, "]");
    return off;
}

// format_call renders the counterexample as a readable call: flat leaves are regrouped into the
// original arguments, with struct parameters in brace form and arrays in bracket form, e.g.
// `f(3, {0, 1}, [-1])`.
static void format_call(const Function *fn, const Value *args, char *buf, size_t cap) {
    int off  = snprintf(buf, cap, "%s(", fn->name);
    int leaf = 0;
    for (int p = 0; p < fn->param_count && (size_t)off < cap; p++) {
        if (p > 0) {
            off += snprintf(buf + off, cap - (size_t)off, ", ");
        }
        if (fn->param_kind[p] == 's') {
            off += snprintf(buf + off, cap - (size_t)off, "{");
            for (int j = 0; j < fn->param_leaves[p] && (size_t)off < cap; j++, leaf++) {
                if (j > 0) {
                    off += snprintf(buf + off, cap - (size_t)off, ", ");
                }
                off += format_leaf(buf + off, cap - (size_t)off, fn->leaf_kind[leaf], args[leaf]);
            }
            off += snprintf(buf + off, cap - (size_t)off, "}");
        } else if (fn->param_kind[p] == 'a') {
            off += format_array(buf + off, cap - (size_t)off, fn->leaf_elem[leaf], args[leaf]);
            leaf++;
        } else {
            off += format_leaf(buf + off, cap - (size_t)off, fn->leaf_kind[leaf], args[leaf]);
            leaf++;
        }
    }
    snprintf(buf + off, cap - (size_t)off, ")");
}

int vm_check(VM *vm, const Tracer *tracer) {
    (void)tracer;
    const CompiledProgram *prog = vm->heap->prog;
    g_check_rng    = 0x9E3779B97F4A7C15ULL;   // fixed seed ⇒ reproducible counterexamples
    vm->check_mode = 1;
    int checked = 0, failures = 0;
    for (int fi = 0; fi < prog->count; fi++) {
        const Function *fn = &prog->functions[fi];
        if (!fn->checkable) {
            continue;
        }
        checked++;
        int argc = fn->leaf_count;     // stack slots to push: one per leaf (struct params flattened)
        Value args[CHECK_MAX_LEAVES];
        int found = 0, rejects = 0, ran = 0;
        for (int t = 0; t < CHECK_TRIALS && !found && rejects <= CHECK_MAX_REJECTS; ) {
            for (int i = 0; i < argc; i++) {
                args[i] = fn->leaf_kind[i] == 'a'
                            ? gen_array(vm, fn->leaf_elem[i], fn->leaf_aek[i])
                            : gen_scalar(fn->leaf_kind[i]);
            }
            VMResult r = run_one_trial(vm, fi, args, argc);
            if (r == VM_RUNTIME_ERROR && vm->check_msg != NULL &&
                strncmp(vm->check_msg, "precondition", 12) == 0) {
                rejects++;            // input out of the function's domain — reject, regenerate
                continue;
            }
            t++;
            ran++;
            if (r == VM_RUNTIME_ERROR) {
                shrink(vm, fi, args, argc, fn);   // minimise the counterexample
                run_one_trial(vm, fi, args, argc);  // re-run the minimal args so check_msg matches
                char call[256];
                format_call(fn, args, call, sizeof call);
                const char *detail = vm->check_msg ? vm->check_msg : "runtime error (crash)";
                printf("check %s: FAILED\n", fn->name);
                printf("  counterexample: %s  =>  %s\n", call, detail);
                printf("{\"event\":\"check_failed\",\"fn\":\"%s\",\"input\":\"%s\","
                       "\"detail\":\"%s\"}\n", fn->name, call, detail);
                found = 1;
                failures++;
            }
        }
        if (!found) {
            printf("check %s: ok (%d cases)\n", fn->name, ran);
        }
    }
    vm->check_mode = 0;
    if (checked == 0) {
        printf("no checkable functions (need a free, non-generic function with an "
               "`ensures` and all-scalar parameters)\n");
    } else {
        printf("checked %d function(s): %d passed, %d failed\n",
               checked, checked - failures, failures);
    }
    return failures;
}





void vm_destroy(VM *vm) {
    free_objects(vm);
#if EMBER_PARALLEL
    pthread_mutex_destroy(&vm->heap->lock);
#endif
    for (int i = 0; i < vm->nondet_count; i++) {
        free(vm->nondet_log[i].str);     // owned byte copies of recorded strings (NULL for scalars)
    }
    free(vm->nondet_log);
    free(vm->cap_buf);
    free(vm->heap);
#if !EMBER_MN
    free(vm->current);   // the main fiber (M:N retires + frees it in the scheduler — don't double-free)
#endif
    free(vm);
}
