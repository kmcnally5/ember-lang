// error_mixed_numeric.em — no implicit coercion: int + float is rejected.
fn main() -> int {
    return 1 + 2.0
}
