// error_int_literal_range.em — locks REVIEW_FINDINGS M14: an integer LITERAL whose digits exceed
// i64 is a compile error, not a silent clamp. 9223372036854775808 is i64 max + 1. (Distinct from
// error_int_overflow.em, which traps at RUNTIME on arithmetic; this is caught at parse time.)
// Before the fix, strtoll clamped to LLONG_MAX and the checker accepted the wrong value as in-range.
fn main() -> int {
    let x = 9223372036854775808
    return x
}
