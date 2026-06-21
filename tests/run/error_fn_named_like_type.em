// error_fn_named_like_type.em — OFI-066: a free function named like a numeric type is rejected,
// because a call `i32(x)` parses as a width conversion and would never reach the function (it used
// to be silently unreachable). Width conversions and a method named i32 stay legal; only a FREE
// function with a width-type name is the error. main is kept independent so the only diagnostic is
// the declaration error itself (no cascade).
fn i32(x: int) -> int {
    return x + 100
}


fn main() -> int {
    return 0
}
