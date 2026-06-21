// ledger.c — the GENERATOR half of Ledger, Ember's resource-LINEARITY fuzzer.
//
// Crucible fuzzes runtime MEMORY ownership; Ceilings fuzzes narrow bytecode operands; Ledger fuzzes
// the third recurring class — the compile-time MUST-CONSUME analysis for a linear `Ptr` FFI handle
// (OFI-049). A `Ptr` must be closed (move-consumed) exactly once on EVERY control-flow path, and the
// checker proves it with an AND-merge (`consumed`) dual to the affine OR-merge (`moved`). That dual is
// the most error-prone code in the checker — the divergence handling at if/match joins and the
// loop-exit merge over `break` paths all have to be inverted exactly. Hand tests cover a handful of
// shapes; this generates THOUSANDS of nested control-flow shapes, each with a KNOWN accept/reject
// oracle (does every path close the handle?), so the driver (ledger.sh) can assert the compiler's
// verdict matches — catching BOTH unsoundness (a leak that compiles) and over-strictness (correct
// code rejected, e.g. the textbook close-on-break read loop).
//
//   tools/ledger <seed>        prints one Ember program to stdout, prefixed with `//EXPECT:accept`
//                              or `//EXPECT:reject` (a leak on some path).
//
// The generator is intentionally SIMPLE so its oracle is self-evidently correct: closes happen only at
// the LEAVES of a branch tree (no two closes on one path, so no accidental double-close), and the loop
// shape never closes after the loop (so the only close axis is "did every break path close?"). Same
// seed ⇒ same program ⇒ reproducible.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// A small splitmix64 PRNG — deterministic from the seed, no platform RNG (matches the dependency-free
// rule; Date/rand are not used so runs reproduce exactly).
static unsigned long long S;

// A per-program counter so every emitted binding has a unique name (a reused `let _c` would be a
// redeclaration error and mask the real verdict). Reset at the start of each shape.
static int VN;


static int vn(void) {
    return VN++;
}


static unsigned rnd(unsigned n) {
    S += 0x9E3779B97F4A7C15ULL;
    unsigned long long z = S;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    z =  z ^ (z >> 31);
    return n == 0 ? 0 : (unsigned)(z % n);
}


static void ind(int d) {
    for (int i = 0; i < d; i++) {
        fputs("    ", stdout);
    }
}


// The shared header: the FFI handle externs + a borrow op. `run` takes the conditions it needs as
// parameters, so each branch condition is a genuine unknown (the checker can't fold it away and prove
// a branch dead — which would change reachability and the oracle).
static void header(void) {
    puts("extern \"c\" {");
    puts("    fn fopen(path: string, mode: string) -> Ptr");
    puts("    fn fwrite(buf: [u8], n: i64, f: Ptr) -> i64");
    puts("    fn fclose(move f: Ptr) -> i64");
    puts("}");
    puts("");
}


// gen_tree emits a region that operates on the OPEN handle `h`, nested to `depth`, at source indent
// `d`. It returns 1 iff EVERY path through the region closes `h` exactly once. Closes happen only at
// leaves, so no path can close twice. A leaf may also `return` (a divergent exit) to exercise the
// per-return leak scan; a returning leaf still must close on its own path, so the oracle is unchanged.
static int gen_tree(const char *h, int depth, int d) {
    int leaf = (depth <= 0) || (rnd(100) < 40);
    if (leaf) {
        if (rnd(2)) {                                   // an optional borrow (safe: h still open)
            ind(d); printf("let _b%d = fwrite(buf, 1, %s)\n", vn(), h);
        }
        int closes = (rnd(100) < 60);
        if (closes) {
            ind(d); printf("let _c%d = fclose(%s)\n", vn(), h);
        }
        if (rnd(100) < 25) {                            // a divergent leaf: exercise the return scan
            ind(d); puts("return 0");
        }
        return closes;
    }
    int kind = rnd(2);
    if (kind == 0) {                                    // if / else — the AND-merge of two branches
        ind(d); puts("if cond {");
        int a = gen_tree(h, depth - 1, d + 1);
        ind(d); puts("} else {");
        int b = gen_tree(h, depth - 1, d + 1);
        ind(d); puts("}");
        return a && b;                                  // closed on every path ⇔ closed on both
    }
    // match Option<int> — exhaustive two-arm AND-fold
    ind(d); puts("match o {");
    ind(d); printf("case Some(_n%d) {\n", vn());
    int a = gen_tree(h, depth - 1, d + 1);
    ind(d); puts("}");
    ind(d); puts("case None {");
    int b = gen_tree(h, depth - 1, d + 1);
    ind(d); puts("}");
    ind(d); puts("}");
    return a && b;
}


// Shape TREE: open one handle, run a branch tree over it, then `return 0`. Accept iff the tree closes
// on every path (so the trailing return sees the handle consumed).
static int shape_tree(void) {
    VN = 0;
    int depth = 1 + (int)rnd(4);
    // Buffer the tree to a temp file? No — we need the verdict BEFORE printing the EXPECT line, and the
    // tree's close decisions are made as it prints. So print the body to a memory buffer first.
    char *buf = NULL;
    size_t cap = 0;
    FILE *mem = open_memstream(&buf, &cap);
    FILE *save = stdout;
    stdout = mem;
    int closed = 0;
    {   // emit the body into the memstream
        ind(1); puts("var f = fopen(\"/tmp/ledger.txt\", \"w\")");
        closed = gen_tree("f", depth, 1);
        ind(1); puts("return 0");
    }
    fflush(mem);
    stdout = save;
    fclose(mem);
    int accept = closed;
    printf("//EXPECT:%s\n", accept ? "accept" : "reject");
    header();
    puts("fn run(cond: bool, o: Option<int>, buf: [u8]) -> int {");
    fputs(buf, stdout);
    puts("}");
    puts("");
    puts("fn main() -> int {");
    puts("    let b: [u8] = [65]");
    puts("    let _r = run(true, Some(1), b)");
    puts("    return 0");
    puts("}");
    free(buf);
    return accept;
}


// Shape LOOP: an infinite `loop` whose ONLY exits are `break`s; each break leaf either closes the
// handle first or not. There is NO close after the loop, so the oracle is exactly "does every break
// path close?". This is the close-on-break read loop and its leak variants (CRITICAL-6). To guarantee
// the after-loop code is reachable (so `f`'s leak is judged on the break paths, not a dead function
// end), at least one break is always emitted.
static int shape_loop(void) {
    VN = 0;
    int nbreaks = 1 + (int)rnd(3);
    int all_close = 1;
    char *buf = NULL;
    size_t cap = 0;
    FILE *mem = open_memstream(&buf, &cap);
    FILE *save = stdout;
    stdout = mem;
    {
        ind(1); puts("var f = fopen(\"/tmp/ledger.txt\", \"w\")");
        ind(1); puts("loop {");
        ind(2); printf("let _b%d = fwrite(buf, 1, f)\n", vn());        // a borrow each iteration (safe)
        // Every exit is a CONDITIONAL break (`if condN { [close] break }`) — the realistic read-loop
        // idiom. The close sits on the break's (diverging) path, so it never reaches the loop back-edge:
        // the older "moved inside a loop body" guard correctly leaves it alone (an UNCONDITIONAL close
        // at the body's top level WOULD trip that guard — a separate, pre-existing over-conservatism,
        // see OFI). An infinite `loop` whose only exits are these breaks is fine: the after-loop state
        // is the AND over the break paths, so accept ⇔ every break closes.
        for (int i = 0; i < nbreaks; i++) {
            ind(2); printf("if cond%d {\n", i);
            int closes = (rnd(100) < 65);
            if (closes) {
                ind(3); printf("let _c%d = fclose(f)\n", vn());
            } else {
                all_close = 0;
            }
            ind(3); puts("break");
            ind(2); puts("}");
        }
        ind(1); puts("}");
        ind(1); puts("return 0");
    }
    fflush(mem);
    stdout = save;
    fclose(mem);
    int accept = all_close;
    printf("//EXPECT:%s\n", accept ? "accept" : "reject");
    header();
    fputs("fn run(", stdout);
    for (int i = 0; i < nbreaks; i++) {
        printf("cond%d: bool, ", i);
    }
    puts("buf: [u8]) -> int {");
    fputs(buf, stdout);
    puts("}");
    puts("");
    puts("fn main() -> int {");
    puts("    let b: [u8] = [65]");
    fputs("    let _r = run(", stdout);
    for (int i = 0; i < nbreaks; i++) {
        fputs("true, ", stdout);
    }
    puts("b)");
    puts("    return 0");
    puts("}");
    free(buf);
    return accept;
}


// Shape REASSIGN: a straight-line sequence over a `var f: Ptr` that is opened, optionally closed, then
// reassigned, optionally closed… Accept iff every open before a reassignment/scope-end is closed first.
static int shape_reassign(void) {
    VN = 0;
    int steps = 2 + (int)rnd(3);
    int accept = 1;
    char *buf = NULL;
    size_t cap = 0;
    FILE *mem = open_memstream(&buf, &cap);
    FILE *save = stdout;
    stdout = mem;
    {
        ind(1); puts("var f = fopen(\"/tmp/ledger.txt\", \"w\")");
        for (int i = 0; i < steps; i++) {
            int close_now = (rnd(100) < 60);
            if (close_now) {
                ind(1); printf("let _c%d = fclose(f)\n", vn());
            }
            if (i + 1 < steps) {
                if (!close_now) {
                    accept = 0;             // reassigning an open handle leaks it
                }
                ind(1); puts("f = fopen(\"/tmp/ledger.txt\", \"w\")");
            } else if (!close_now) {
                accept = 0;                 // the last handle reaches scope end un-closed
            }
        }
        ind(1); puts("return 0");
    }
    fflush(mem);
    stdout = save;
    fclose(mem);
    printf("//EXPECT:%s\n", accept ? "accept" : "reject");
    header();
    puts("fn main() -> int {");
    fputs(buf, stdout);
    puts("}");
    free(buf);
    return accept;
}


int main(int argc, char **argv) {
    unsigned long long seed = (argc > 1) ? strtoull(argv[1], NULL, 10) : 1;
    S = seed * 0x2545F4914F6CDD1DULL + 0x123456789ULL;
    switch ((int)rnd(3)) {
        case 0:  return shape_tree()     ? 0 : 0;
        case 1:  return shape_loop()     ? 0 : 0;
        default: return shape_reassign() ? 0 : 0;
    }
}
