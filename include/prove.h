#ifndef EMBER_PROVE_H
#define EMBER_PROVE_H

#include "ast.h"

// Verification loop (§5j, brick 4): statically PROVE function contracts in a decidable fragment —
// quantifier-free linear integer arithmetic over the integer parameters of a single-return
// function. For each provable `ensures` the prover substitutes `result` with the body's returned
// expression and discharges `requires ⟹ ensures` by showing `requires ∧ ¬ensures` is infeasible
// (Fourier–Motzkin over the rationals, which is sound for the integers). Clauses outside the
// fragment, or not provable, are reported as "use --check" — the property-based fallback (brick 2).
// Prints a per-clause report and a summary; returns the number of clauses it could not prove.
int prove_program(const Program *program);

// prove_fn_verdicts fills out_proved[i] (1 = statically discharged, 0 = not) for each of `fn`'s
// ensures clauses — the SAME proof --emit=prove reports, but as data (no printing). `out_proved`
// must hold at least fn->ensures_count entries. Returns the number proved. The language server uses
// this to mark each contract's verification status in the editor (the verification-loop differentiator).
int prove_fn_verdicts(const FnDecl *fn, int *out_proved);

#endif // EMBER_PROVE_H
