// Native backend (M5) differential test: the `extern "c"` FFI. The compiled binary
// dispatches through the in-tree C registry (em_ffi -> cextern_call), the same one the
// VM uses, so the result must match. strlen is pure (no I/O), keeping the test
// deterministic; the string is BORROWED across the call (Ember frees nothing C owns).
extern "c" {
    fn strlen(s: string) -> i64
    fn strncmp(a: string, b: string, n: i64) -> i32
}

fn main() -> int {
    let a = "hello, ember"
    let n = strlen(a)                         // 12
    println("strlen = {n}")
    let eq = strncmp("ember", "embers", i64(5))   // 0 (first 5 bytes equal)
    let ne = strncmp("ab", "xy", i64(2))          // negative
    println("eq = {eq}")
    if ne < 0 { println("ne ok") }
    return int(n) + int(eq)                   // 12 + 0 = 12
}
