// assert.em (trace) — a failing assert surfaces as a structured contract_violation event on the
// execution tape: the machine-readable counterexample the agent-correctness loop is built on (§5j).
fn main() -> int {
    let n = 3
    assert(n == 4, "n must be four")
    return n
}
