#include "prove.h"
#include "token.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Brick 4 of the verification loop (§5j): a small, SOUND, dependency-free prover for contracts in
// the linear-integer-arithmetic fragment. It never claims a false contract is proved — anything it
// cannot model or discharge is reported as "use --check", deferring to the property fuzzer (brick
// 2). All arithmetic is exact int64 with overflow guards; on any overflow or blow-up the proof
// attempt bails to "not proved" so the result stays sound.

#define PROVE_MAX_VARS    8      // integer parameters tracked per function
#define PROVE_MAX_CONSTR  128    // constraint budget before a proof attempt bails (FM can blow up)
#define PROVE_MAX_ATOMS   32     // conjuncts in one contract clause





// A linear form  Σ coeff[i]·varᵢ + konst  over the tracked integer parameters.
typedef struct {
    long long coeff[PROVE_MAX_VARS];
    long long konst;
} Linear;





// A constraint  L ⊵ 0,  where ⊵ is `>=` (strict 0) or `>` (strict 1).
typedef struct {
    Linear lin;
    int    strict;
} Constraint;





// The variables in scope while reading a contract: the integer parameter names, and (when proving
// an `ensures`) the linear form that `result` stands for. `overflow` latches if any exact-integer
// step would wrap, which forces the current proof attempt to bail soundly.
typedef struct {
    const char  *names[PROVE_MAX_VARS];
    int          nvars;
    const Linear *result;          // what `result` expands to, or NULL
    int          overflow;
} Env;





static long long add_ll(Env *e, long long a, long long b) {
    long long r;
    if (__builtin_add_overflow(a, b, &r)) {
        e->overflow = 1;
        return 0;
    }
    return r;
}





static long long mul_ll(Env *e, long long a, long long b) {
    long long r;
    if (__builtin_mul_overflow(a, b, &r)) {
        e->overflow = 1;
        return 0;
    }
    return r;
}





static long long gcd_ll(long long a, long long b) {
    if (a < 0) { a = -a; }
    if (b < 0) { b = -b; }
    while (b != 0) {
        long long t = a % b;
        a = b;
        b = t;
    }
    return a;
}





// is_int_type reports whether a parameter's declared type is an integer scalar the prover models.
static int is_int_type(const Type *t) {
    if (t == NULL || t->kind != TYPE_NAME || t->as.name.qualifier != NULL) {
        return 0;
    }
    const char *n = t->as.name.name;
    return strcmp(n, "int") == 0 || strcmp(n, "i8") == 0 || strcmp(n, "i16") == 0 ||
           strcmp(n, "i32") == 0 || strcmp(n, "i64") == 0 || strcmp(n, "u8") == 0 ||
           strcmp(n, "u16") == 0 || strcmp(n, "u32") == 0 || strcmp(n, "u64") == 0;
}





// expr_to_linear renders `e` as a linear form over the tracked variables, returning 1 on success.
// It fails (0) on anything outside the fragment: a non-tracked name, a non-constant product, a
// reference to `result` when no result form is available, division, calls, and so on.
static int expr_to_linear(Env *env, const Expr *e, Linear *out) {
    memset(out, 0, sizeof *out);
    switch (e->kind) {
        case EXPR_INT:
            out->konst = e->as.int_lit;
            return 1;

        case EXPR_IDENT: {
            if (env->result != NULL && strcmp(e->as.ident, "result") == 0) {
                *out = *env->result;
                return 1;
            }
            for (int i = 0; i < env->nvars; i++) {
                if (strcmp(e->as.ident, env->names[i]) == 0) {
                    out->coeff[i] = 1;
                    return 1;
                }
            }
            return 0;
        }

        case EXPR_UNARY: {
            if (e->as.unary.op != TOK_MINUS) {
                return 0;
            }
            if (!expr_to_linear(env, e->as.unary.operand, out)) {
                return 0;
            }
            for (int i = 0; i < env->nvars; i++) {
                out->coeff[i] = mul_ll(env, out->coeff[i], -1);
            }
            out->konst = mul_ll(env, out->konst, -1);
            return 1;
        }

        case EXPR_BINARY: {
            Linear l, r;
            if (!expr_to_linear(env, e->as.binary.left, &l) ||
                !expr_to_linear(env, e->as.binary.right, &r)) {
                return 0;
            }
            if (e->as.binary.op == TOK_PLUS || e->as.binary.op == TOK_MINUS) {
                int sign = e->as.binary.op == TOK_PLUS ? 1 : -1;
                for (int i = 0; i < env->nvars; i++) {
                    out->coeff[i] = add_ll(env, l.coeff[i], mul_ll(env, r.coeff[i], sign));
                }
                out->konst = add_ll(env, l.konst, mul_ll(env, r.konst, sign));
                return 1;
            }
            if (e->as.binary.op == TOK_STAR) {
                int l_const = 1, r_const = 1;
                for (int i = 0; i < env->nvars; i++) {
                    if (l.coeff[i] != 0) { l_const = 0; }
                    if (r.coeff[i] != 0) { r_const = 0; }
                }
                const Linear *var = l_const ? &r : &l;     // the non-constant side
                long long      k   = l_const ? l.konst : r.konst;
                if (!l_const && !r_const) {
                    return 0;                               // nonlinear: variable × variable
                }
                for (int i = 0; i < env->nvars; i++) {
                    out->coeff[i] = mul_ll(env, var->coeff[i], k);
                }
                out->konst = mul_ll(env, var->konst, k);
                return 1;
            }
            return 0;
        }

        default:
            return 0;
    }
}





// add_atom appends constraint `lin ⊵ 0` to the set, respecting the budget.
static int add_atom(Constraint *cs, int *n, int cap, Linear lin, int strict) {
    if (*n >= cap) {   // OFI-101: bound against the REAL buffer capacity, not the global constraint budget
        return 0;
    }
    cs[*n].lin    = lin;
    cs[*n].strict = strict;
    (*n)++;
    return 1;
}





static Linear lin_sub(Env *env, Linear a, Linear b) {
    Linear r;
    for (int i = 0; i < env->nvars; i++) {
        r.coeff[i] = add_ll(env, a.coeff[i], mul_ll(env, b.coeff[i], -1));
    }
    r.konst = add_ll(env, a.konst, mul_ll(env, b.konst, -1));
    return r;
}





// clause_to_constraints turns a boolean contract expression into a conjunction of constraints,
// splitting `&&` and equality. Returns 0 if any part is outside the linear fragment (`!=`, `||`,
// calls, …). The appended constraints are the assertion that the clause HOLDS.
static int clause_to_constraints(Env *env, const Expr *e, Constraint *cs, int *n, int cap) {
    if (e->kind == EXPR_BINARY && e->as.binary.op == TOK_AND) {
        return clause_to_constraints(env, e->as.binary.left, cs, n, cap) &&
               clause_to_constraints(env, e->as.binary.right, cs, n, cap);
    }
    if (e->kind != EXPR_BINARY) {
        return 0;
    }
    Linear l, r;
    if (!expr_to_linear(env, e->as.binary.left, &l) ||
        !expr_to_linear(env, e->as.binary.right, &r)) {
        return 0;
    }
    switch (e->as.binary.op) {
        case TOK_LE: return add_atom(cs, n, cap, lin_sub(env, r, l), 0);   // l <= r  ⇒  r - l >= 0
        case TOK_LT: return add_atom(cs, n, cap, lin_sub(env, r, l), 1);   // l <  r  ⇒  r - l >  0
        case TOK_GE: return add_atom(cs, n, cap, lin_sub(env, l, r), 0);
        case TOK_GT: return add_atom(cs, n, cap, lin_sub(env, l, r), 1);
        case TOK_EQ:                                                  // l == r ⇒ both directions
            return add_atom(cs, n, cap, lin_sub(env, l, r), 0) &&
                   add_atom(cs, n, cap, lin_sub(env, r, l), 0);
        default: return 0;
    }
}





// normalize divides a constraint by the gcd of its (nonzero) terms to keep coefficients small.
static void normalize(Linear *lin) {
    long long g = lin->konst < 0 ? -lin->konst : lin->konst;
    for (int i = 0; i < PROVE_MAX_VARS; i++) {
        g = gcd_ll(g, lin->coeff[i]);
    }
    if (g > 1) {
        for (int i = 0; i < PROVE_MAX_VARS; i++) {
            lin->coeff[i] /= g;
        }
        lin->konst /= g;
    }
}





// fm_unsat reports whether the constraint set is infeasible over the rationals (Fourier–Motzkin
// variable elimination). A rational-infeasible system is integer-infeasible too, so a `1` here is
// a sound proof. On overflow or budget exhaustion it returns 0 (cannot prove) — never a false 1.
static int fm_unsat(Env *env, Constraint *cs, int n, int nvars) {
    Constraint cur[PROVE_MAX_CONSTR];
    memcpy(cur, cs, (size_t)n * sizeof(Constraint));

    for (int v = 0; v < nvars; v++) {
        Constraint next[PROVE_MAX_CONSTR];
        int m = 0;
        for (int i = 0; i < n; i++) {            // keep constraints that don't mention v
            if (cur[i].lin.coeff[v] == 0) {
                if (m >= PROVE_MAX_CONSTR) { return 0; }
                next[m++] = cur[i];
            }
        }
        for (int i = 0; i < n; i++) {            // combine each lower/upper bound pair on v
            if (cur[i].lin.coeff[v] <= 0) { continue; }
            for (int j = 0; j < n; j++) {
                if (cur[j].lin.coeff[v] >= 0) { continue; }
                long long b = cur[i].lin.coeff[v];        // > 0
                long long d = -cur[j].lin.coeff[v];       // > 0
                Constraint c;
                c.strict = cur[i].strict || cur[j].strict;
                for (int k = 0; k < PROVE_MAX_VARS; k++) {
                    c.lin.coeff[k] = add_ll(env, mul_ll(env, d, cur[i].lin.coeff[k]),
                                                 mul_ll(env, b, cur[j].lin.coeff[k]));
                }
                c.lin.konst = add_ll(env, mul_ll(env, d, cur[i].lin.konst),
                                          mul_ll(env, b, cur[j].lin.konst));
                if (env->overflow) { return 0; }
                normalize(&c.lin);
                if (m >= PROVE_MAX_CONSTR) { return 0; }
                next[m++] = c;
            }
        }
        memcpy(cur, next, (size_t)m * sizeof(Constraint));
        n = m;
    }

    for (int i = 0; i < n; i++) {                 // all variables gone: check the constants
        long long k = cur[i].lin.konst;
        if ((cur[i].strict && k <= 0) || (!cur[i].strict && k < 0)) {
            return 1;                             // a contradiction: the system is infeasible
        }
    }
    return 0;
}





// prove_clause attempts `requires ⟹ atom` for one ensures atom by checking `requires ∧ ¬atom`
// infeasible. `requires` is the modelled precondition set (out-of-fragment requires were dropped,
// which is sound — fewer assumptions only make proving harder). Returns 1 if proved.
static int prove_clause(Env *env, const Constraint *req, int nreq, Constraint atom) {
    Constraint cs[PROVE_MAX_CONSTR];
    int n = 0;
    for (int i = 0; i < nreq && n < PROVE_MAX_CONSTR; i++) {
        cs[n++] = req[i];
    }
    // ¬(L >= 0) is (-L > 0); ¬(L > 0) is (-L >= 0).
    Constraint neg;
    neg.strict = !atom.strict;
    for (int i = 0; i < PROVE_MAX_VARS; i++) {
        neg.lin.coeff[i] = mul_ll(env, atom.lin.coeff[i], -1);
    }
    neg.lin.konst = mul_ll(env, atom.lin.konst, -1);
    if (env->overflow || n >= PROVE_MAX_CONSTR) {
        return 0;
    }
    cs[n++] = neg;
    return fm_unsat(env, cs, n, env->nvars);
}





// prove_fn_verdicts fills out_proved[i] for each ensures clause of `fn` and returns the count proved
// (see prove.h). This is the proof itself, without any I/O — both --emit=prove (prove_fn, below) and
// the language server drive it.
int prove_fn_verdicts(const FnDecl *fn, int *out_proved) {
    if (fn->ensures_count == 0) {
        return 0;
    }

    Env env = {0};
    for (size_t i = 0; i < fn->param_count; i++) {
        if (fn->params[i].is_self || !is_int_type(fn->params[i].type) ||
            env.nvars >= PROVE_MAX_VARS) {
            env.nvars = -1;          // a parameter outside the fragment: cannot model this function
            break;
        }
        env.names[env.nvars++] = fn->params[i].name;
    }

    // The body's single returned expression is what `result` denotes. Functions with branches or
    // multiple statements fall outside the fragment (their `result` is not one linear form).
    Linear result_lin;
    int have_result = 0;
    if (env.nvars >= 0 && fn->body.count == 1 && fn->body.stmts[0]->kind == STMT_RETURN &&
        fn->body.stmts[0]->as.ret.value != NULL) {
        env.result = NULL;
        if (expr_to_linear(&env, fn->body.stmts[0]->as.ret.value, &result_lin) && !env.overflow) {
            have_result = 1;
        }
    }

    // Model the preconditions once (dropping any clause outside the fragment is sound).
    Constraint req[PROVE_MAX_CONSTR];
    int nreq = 0;
    if (env.nvars >= 0) {
        for (size_t i = 0; i < fn->requires_count; i++) {
            int save = nreq;
            if (!clause_to_constraints(&env, fn->requires_clauses[i], req, &nreq, PROVE_MAX_CONSTR) || env.overflow) {
                nreq = save;         // un-model a partially-added or unmodelable clause
                env.overflow = 0;
            }
        }
    }

    int proved_count = 0;
    for (size_t i = 0; i < fn->ensures_count; i++) {
        const Expr *clause = fn->ensures_clauses[i];
        int proved = 0;
        if (env.nvars >= 0 && have_result) {
            env.result = &result_lin;
            Constraint atoms[PROVE_MAX_ATOMS];
            int natoms = 0;
            if (clause_to_constraints(&env, clause, atoms, &natoms, PROVE_MAX_ATOMS) && !env.overflow && natoms > 0) {
                proved = 1;
                for (int a = 0; a < natoms && proved; a++) {
                    env.overflow = 0;
                    if (!prove_clause(&env, req, nreq, atoms[a])) {
                        proved = 0;
                    }
                }
            }
        }
        out_proved[i] = proved;
        proved_count += proved;
    }
    return proved_count;
}


// prove_fn proves what it can of one function's `ensures` clauses, prints a line per clause, and
// returns the count it could not prove (which the caller tallies for the summary + exit hint).
static int prove_fn(const FnDecl *fn) {
    if (fn->ensures_count == 0) {
        return 0;
    }
    int *verdicts = malloc(fn->ensures_count * sizeof(int));
    prove_fn_verdicts(fn, verdicts);
    int unproved = 0;
    for (size_t i = 0; i < fn->ensures_count; i++) {
        const Expr *clause = fn->ensures_clauses[i];
        if (verdicts[i]) {
            printf("prove %s: ensures @line %d — PROVED\n", fn->name, clause->line);
            printf("{\"event\":\"proved\",\"fn\":\"%s\",\"line\":%d}\n", fn->name, clause->line);
        } else {
            printf("prove %s: ensures @line %d — not proved (use --check)\n",
                   fn->name, clause->line);
            printf("{\"event\":\"unproved\",\"fn\":\"%s\",\"line\":%d}\n", fn->name, clause->line);
            unproved++;
        }
    }
    free(verdicts);
    return unproved;
}





int prove_program(const Program *program) {
    int total = 0, unproved = 0;
    for (size_t i = 0; i < program->count; i++) {
        if (program->decls[i]->kind != DECL_FN) {
            continue;
        }
        const FnDecl *fn = &program->decls[i]->as.fn;
        total += (int)fn->ensures_count;
        unproved += prove_fn(fn);
    }
    if (total == 0) {
        printf("no contract postconditions to prove\n");
    } else {
        printf("proved %d of %d ensures clause(s); %d to check\n",
               total - unproved, total, unproved);
    }
    return unproved;
}
