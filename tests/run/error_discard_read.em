// error_discard_read.em — `_` is a WRITE-ONLY discard wildcard (OFI-095): it binds nothing
// readable, so reading `_` is an undefined-identifier error. This locks in that a discard never
// becomes a back-door readable variable (the prior behavior, where `let _ = 42; return _` => 42).

fn main() -> int {
    let _ = 42
    let y = _
    return y
}
