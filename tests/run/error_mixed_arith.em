// error_mixed_arith.em — locks no-coercion: int + bool is rejected.
fn main() -> int {
    return 1 + (2 > 3)
}
