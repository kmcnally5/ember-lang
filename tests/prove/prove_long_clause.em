// OFI-101: a contract clause with more conjuncts than the prover's atom buffer (PROVE_MAX_ATOMS=32)
// must be DECLINED cleanly (use --check), never overrun the stack. This `ensures` chains 40
// `result >= 0` conjuncts: before the fix add_atom guarded against PROVE_MAX_CONSTR (128) and wrote
// past atoms[32]; now it stops at the real capacity and the clause is reported as not proved.
fn nonneg(a: int) -> int
    requires a >= 0
    ensures result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0 && result >= 0
{
    return a
}
