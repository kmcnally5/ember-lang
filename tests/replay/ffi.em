// ffi.em — verification loop (§5j) brick 3, foreign-call results: every `extern "c"` (OP_CALL_C)
// result leaf is recorded and replayed, so a program calling C — even a nondeterministic C
// function — reproduces exactly without re-invoking C. (libm here is deterministic; the point is
// the capture/replay path: 5 ffi events, both runs identical.)
extern "c" {
    fn sin(x: f64) -> f64
    fn cos(x: f64) -> f64
    fn hypot(a: f64, b: f64) -> f64
    fn log2(x: f64) -> f64
}


fn main() -> int {
    let s = sin(0.0)
    let c = cos(0.0)
    let h = hypot(3.0, 4.0)
    let l = log2(8.0)
    println("sin0+cos0 = {s + c}")
    println("hypot 3,4 = {h}")
    println("log2 8 = {l}")
    return to_int((s + c + h + l) * 1000.0)
}
