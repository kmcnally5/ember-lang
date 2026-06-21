// error_duplicate_fn.em — two top-level functions of the same name in one module
// are rejected. Without this, every call would silently bind to the first and the
// second would be unreachable dead code (OFI-008).
fn area(n: int) -> int { return n * n }
fn area(n: int) -> int { return n + n }
fn main() -> int { return area(4) }
