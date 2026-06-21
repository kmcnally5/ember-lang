// error_global_non_literal.em — a top-level constant must be a literal value; a
// non-literal initializer (a function call) is rejected (OFI-023; general runtime
// globals are deliberate future work).
fn two() -> int {
    return 2
}

let X = two()

fn main() -> int {
    return X
}
