// crucible.c — the GENERATOR half of Crucible, Ember's memory-ownership fuzzer (a build-time dev
// tool, not shipped in emberc). Given a seed it prints ONE valid Ember program to stdout that
// stresses the danger zone where our memory bugs keep living: value-structs (all-scalar, with a
// heap string field, and nested), placed into erased-generic aggregates ([T], Map<string,T>,
// Option<T>, and nested combinations), passed by move and by borrow, returned, read back, mutated
// through an array index, and interpolated — in loops and via reassignment.
//
// Each danger pattern is emitted as a SELF-CONTAINED function `opN() -> int` that folds the values
// it touches into a local `acc` and returns it; `main` sums the ops and prints the total. So the
// output is a checksum the driver compares VM-vs-native (a dropped/duplicated value changes it), the
// op functions keep `main` tiny (no constant-pool blowup), and the driver can SHRINK a failure by
// simply deleting `+ opK()` terms. Deterministic: same seed => same program => reproducible.
//
// "No knowledge lost": every combination that has bitten us (OFI-057/058/059/061/062/064) lives in
// the space this samples, so the same class of bug can't come back unseen. (OFI-064 — binding a
// value-struct out of a `match` case into an outer var — was a blind spot until op_match_bind_out.) The driver (tools/crucible.sh)
// runs each program through the double-drop detector, ASan, an RSS leak check, and the VM↔native
// differential, dedups by signature, and shrinks each distinct finding to a minimal repro.

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

static uint64_t g_rng;

static uint64_t rng_next(void) {
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 7;
    g_rng ^= g_rng << 17;
    return g_rng;
}

static int rnd(int n) {
    return n <= 1 ? 0 : (int)(rng_next() % (uint64_t)n);
}

// Struct shape: 0 all-scalar, 1 +string field, 2 +nested struct, 3 +string +nested.
static int g_shape;
static int has_string(void) { return g_shape == 1 || g_shape == 3; }
static int has_nested(void) { return g_shape == 2 || g_shape == 3; }

// rc mode (seed >= CRUCIBLE_RC_BASE): S (and Inner, if nested) is declared `rc struct`, so the SAME
// aggregate operations route through the rc representation — boxed + refcounted, own_into_slot RETAINs
// (no deep-clone), drop_value reclaims at the last owner. Only rc-SAFE ops run (no field mutation,
// no .clone()), since an rc value is immutable. Catches rc representation drift / double-free / leak.
#define CRUCIBLE_RC_BASE 1000000ULL
static int g_rc;

// Loop trip count, scalable so the driver can compare RSS at two sizes (leak oracle).
static long g_loops;

static int g_need_pair, g_need_keep, g_need_some;
static const char *g_strs[] = { "ab", "xyz", "q", "hello", "z", "longerstring" };

// `S { … }` literal with seed-chosen field values.
static void emit_lit(void) {
    printf("S { a: %d", rnd(100));
    if (has_string()) printf(", s: \"%s\"", g_strs[rnd(6)]);
    if (has_nested()) printf(", inner: Inner { x: %d }", rnd(100));
    printf(" }");
}

// `acc = acc + v.a [+ v.inner.x] [+ v.s.len()]` — reads every field so heap/nested leaves are
// exercised, not just the scalar.
static void emit_acc(const char *v) {
    printf("    acc = acc + %s.a", v);
    if (has_nested()) printf(" + %s.inner.x", v);
    if (has_string()) printf(" + %s.s.len()", v);
    printf("\n");
}


// ---- the operations (each emits the BODY of an opN function, folding into local `acc`) ----------
static void op_array_generic(void) {        // build [T] via a generic from borrowed args, read both
    printf("    let xs = c_pair(");
    emit_lit(); printf(", "); emit_lit(); printf(")\n");
    emit_acc("xs[0]"); emit_acc("xs[1]");
}

static void op_map_struct(void) {           // Map<string, S> set/overwrite/get
    printf("    var m = map.Map<string, S>{ buckets: [], count: 0 }\n");
    printf("    m.set(\"k0\", "); emit_lit(); printf(")\n");
    printf("    m.set(\"k1\", "); emit_lit(); printf(")\n");
    printf("    m.set(\"k0\", "); emit_lit(); printf(")\n");
    printf("    match m.get(\"k0\") { case Some(v) {\n");
    emit_acc("v");
    printf("    } case None {} }\n");
    printf("    match m.get(\"k1\") { case Some(v) {\n");
    emit_acc("v");
    printf("    } case None {} }\n");
}

static void op_field_mutate(void) {         // arr[i].field = … in a loop (OFI-061 path)
    printf("    var arr: [S] = ["); emit_lit(); printf(", "); emit_lit(); printf("]\n");
    printf("    var i = 0\n    loop {\n        if i == arr.len() { break }\n");
    printf("        arr[i].a = arr[i].a + 7\n");
    if (has_string()) printf("        arr[i].s = \"%s\"\n", g_strs[rnd(6)]);
    printf("        i = i + 1\n    }\n");
    emit_acc("arr[0]"); emit_acc("arr[1]");
}

static void op_generic_move(void) {         // pass to a generic by MOVE, return the erased T
    printf("    let r = c_keep("); emit_lit(); printf(")\n");
    emit_acc("r");
}

static void op_option(void) {               // Option<S> via a generic, matched + unwrapped
    printf("    let o = c_some("); emit_lit(); printf(")\n");
    printf("    match o { case Some(v) {\n");
    emit_acc("v");
    printf("    } case None {} }\n");
}

static void op_nested_map_array(void) {     // Map<string, [S]> — a struct array as a Map value
    printf("    var m = map.Map<string, [S]>{ buckets: [], count: 0 }\n");
    printf("    m.set(\"k\", ["); emit_lit(); printf(", "); emit_lit(); printf("])\n");
    printf("    match m.get(\"k\") { case Some(v) {\n");
    emit_acc("v[0]"); emit_acc("v[1]");
    printf("    } case None {} }\n");
}

static void op_interp_loop(void) {          // interpolation in a loop with reassignment (OFI-059)
    printf("    var i = 0\n    var last = \"\"\n");
    printf("    loop {\n        if i == %ld { break }\n", g_loops);
    printf("        last = \"row{i}-x{i}-end\"\n        i = i + 1\n    }\n");
    printf("    acc = acc + last.len()\n");
}

static void op_array_loop(void) {           // build + read a struct array every iteration (leak soak)
    printf("    var i = 0\n    loop {\n        if i == %ld { break }\n", g_loops);
    printf("        let xs = c_pair("); emit_lit(); printf(", "); emit_lit(); printf(")\n");
    printf("        acc = acc + xs[0].a + xs[1].a\n        i = i + 1\n    }\n");
    g_need_pair = 1;
}

static void op_match_bind_out(void) {       // OFI-064: bind a value-struct out of a `match` case into
    // a PRE-EXISTING outer var, then mutate the copy. The bind must DEEP-COPY (value semantics), not
    // alias the scrutinee's payload — else the two owners double-free at drop, and mutating one bleeds
    // into the other (so re-reading the source after the mutation also changes the checksum). The prior
    // ops only read scalar fields INSIDE the case (the safe path), so this shape was the blind spot.
    printf("    let o = c_some("); emit_lit(); printf(")\n");
    printf("    var d = "); emit_lit(); printf("\n");
    printf("    match o { case Some(v) { d = v } case None {} }\n");
    printf("    d.a = d.a + 1\n");
    emit_acc("d");
    printf("    match o { case Some(v) {\n");           // source must be untouched by d's mutation
    emit_acc("v");
    printf("    } case None {} }\n");
    // The window-registry shape: get a struct out of a Map into an outer var, mutate it, write it back.
    printf("    var m = map.Map<string, S>{ buckets: [], count: 0 }\n");
    printf("    m.set(\"k\", "); emit_lit(); printf(")\n");
    printf("    var e = "); emit_lit(); printf("\n");
    printf("    match m.get(\"k\") { case Some(v) { e = v } case None {} }\n");
    printf("    e.a = e.a + 1\n");
    printf("    m.set(\"k\", e)\n");
    printf("    match m.get(\"k\") { case Some(v) {\n");
    emit_acc("v");
    printf("    } case None {} }\n");
    g_need_some = 1;
}


static void op_clone(void) {                // OFI-082: deep-clone a [S]; the copy must be INDEPENDENT.
    // Array clone deep-copies each value-struct element (own_into_slot per leaf), so it exercises the
    // value-struct clone path while staying supported on BOTH backends (so it rides the diff oracle).
    // Growing / mutating the clone must not touch the source, and no leaf may be double-freed at drop.
    printf("    var xs: [S] = ["); emit_lit(); printf(", "); emit_lit(); printf("]\n");
    printf("    var ys = xs.clone()\n");
    printf("    ys.append("); emit_lit(); printf(")\n");      // grow the clone alone
    printf("    ys[0].a = ys[0].a + 5\n");                     // mutate a clone element in place
    emit_acc("xs[0]"); emit_acc("xs[1]");                      // source untouched by ys's growth/mutation
    emit_acc("ys[0]"); emit_acc("ys[1]"); emit_acc("ys[2]");
}


static void op_array_remove_at(void) {      // OFI-072: remove_at(i) on a value-struct array. The removed
    // element MOVES out (its heap leaves transfer to the caller, no retain); the survivors shift down one
    // slot keeping their single owner; the excess last slot is excluded by the shrunk length. So no leaf
    // may be double-freed at drop and none may leak. Runs on BOTH backends → rides the VM↔native diff oracle.
    printf("    var xs: [S] = [");
    emit_lit(); printf(", "); emit_lit(); printf(", "); emit_lit();
    printf("]\n");
    printf("    let removed = xs.remove_at(1)\n");   // remove the middle → the tail shifts into [1..]
    emit_acc("removed");                              // read the moved-out element's leaves
    emit_acc("xs[0]"); emit_acc("xs[1]");             // survivors at their shifted slots
    printf("    acc = acc + xs.len()\n");
}


static void op_array_remove_last(void) {    // remove_last() on a value-struct array (was uncovered too):
    // the last element moves out, the rest stay put; no leaf double-freed/leaked.
    printf("    var xs: [S] = [");
    emit_lit(); printf(", "); emit_lit();
    printf("]\n");
    printf("    let last = xs.remove_last()\n");
    emit_acc("last");
    emit_acc("xs[0]");
    printf("    acc = acc + xs.len()\n");
}


typedef void (*OpFn)(void);
static OpFn OPS[] = {
    op_array_generic, op_map_struct, op_field_mutate, op_generic_move,
    op_option, op_nested_map_array, op_interp_loop, op_array_loop, op_match_bind_out,
    op_clone, op_array_remove_at, op_array_remove_last,
};
static const int N_OPS = (int)(sizeof(OPS) / sizeof(OPS[0]));

// The rc-SAFE subset: ops that never mutate an S field or call .clone() (both illegal on an
// immutable rc value), so an `rc struct` S compiles. They still share S into [T] / Map / Option /
// nested aggregates, move it through a generic, churn it in a loop (leak soak), and move it out of an
// array — exercising own_into_slot RETAIN, the refcounted drop, and VM↔native parity for rc.
static OpFn RC_OPS[] = {
    op_array_generic, op_map_struct, op_generic_move, op_option,
    op_nested_map_array, op_array_loop, op_array_remove_at, op_array_remove_last,
};
static const int N_RC_OPS = (int)(sizeof(RC_OPS) / sizeof(RC_OPS[0]));

// Which helpers an op needs (so they're declared before use).
static void note_helpers(OpFn fn) {
    if (fn == op_array_generic || fn == op_array_loop)   g_need_pair = 1;
    if (fn == op_generic_move)                           g_need_keep = 1;
    if (fn == op_option || fn == op_match_bind_out)      g_need_some = 1;
}


int main(int argc, char **argv) {
    uint64_t seed = (argc > 1) ? strtoull(argv[1], NULL, 10) : 1;
    g_loops = (argc > 2) ? strtol(argv[2], NULL, 10) : 30;     // driver scales this for the leak oracle
    g_rng = seed ? seed : 0x9E3779B97F4A7C15ULL;
    g_rc  = (seed >= CRUCIBLE_RC_BASE);                        // high seed range => rc-struct mode
    g_shape = rnd(4);

    OpFn      *tbl   = g_rc ? RC_OPS : OPS;                    // rc mode uses only the rc-safe ops
    const int  n_tbl = g_rc ? N_RC_OPS : N_OPS;

    int n_ops = 2 + rnd(6);                                    // 2..7 ops
    int ops[8];
    for (int i = 0; i < n_ops; i++) { ops[i] = rnd(n_tbl); note_helpers(tbl[ops[i]]); }

    printf("// crucible seed=%llu shape=%d rc=%d ops=%d loops=%ld — generated; do not edit.\n",
           (unsigned long long)seed, g_shape, g_rc, n_ops, g_loops);
    printf("import \"std/map\" as map\n\n");
    if (has_nested()) printf("%sstruct Inner { x: int }\n\n", g_rc ? "rc " : "");
    printf("%sstruct S {\n    a: int\n", g_rc ? "rc " : "");
    if (has_string()) printf("    s: string\n");
    if (has_nested()) printf("    inner: Inner\n");
    printf("}\n\n");
    if (g_need_pair) printf("fn c_pair<T>(a: T, b: T) -> [T] { return [a, b] }\n");
    if (g_need_keep) printf("fn c_keep<T>(move x: T) -> T { return x }\n");
    if (g_need_some) printf("fn c_some<T>(move x: T) -> Option<T> { return Some(x) }\n");
    if (g_need_pair || g_need_keep || g_need_some) printf("\n");

    for (int i = 0; i < n_ops; i++) {
        printf("fn op%d() -> int {\n    var acc = 0\n", i);
        tbl[ops[i]]();
        printf("    return acc\n}\n\n");
    }

    printf("fn main() -> int {\n    var total = 0\n");
    for (int i = 0; i < n_ops; i++) {
        printf("    total = total + op%d()\n", i);
    }
    printf("    print(\"{total}\")\n    return 0\n}\n");
    return 0;
}
