// contract_violation.em — a violated postcondition surfaces on the trace seam as a
// structured `contract_violation` event (MANIFESTO §5c/§5e): machine-readable feedback
// for an LLM author, not just an abort. The last tape line is the semantic event.
fn half(x: int) -> int
    ensures result + result == x
{
    return x / 2          // odd x loses the remainder → postcondition fails
}

fn main() -> int {
    return half(7)
}
