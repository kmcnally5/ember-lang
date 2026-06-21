// error_int_overflow.em — integer overflow traps at runtime (no UB; OFI-005).
fn main() -> int {
    return 9223372036854775807 * 2
}
