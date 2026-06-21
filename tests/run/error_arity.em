// error_arity.em — calling with the wrong number of arguments is a compile error.
fn add(a: int, b: int) -> int { return a + b }
fn main() -> int { return add(1) }
