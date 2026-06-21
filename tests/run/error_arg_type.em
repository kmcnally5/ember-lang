// error_arg_type.em — argument type must match the parameter (no coercion).
fn takes_int(x: int) -> int { return x }
fn main() -> int { return takes_int(true) }
