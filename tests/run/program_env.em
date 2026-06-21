// program_env.em — args() and env(). Deterministic under the test harness: it passes no
// program arguments (args() is empty) and the probed variable is unset (env() -> "").
fn main() -> int {
    let a = args()                                   // no args here -> length 0
    let missing = env("EMBER_DEFINITELY_UNSET_XYZ")  // unset -> ""
    var n = a.len()
    if missing == "" { n = n + 5 }
    return n                                          // 0 + 5 = 5
}
