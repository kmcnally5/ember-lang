// errors_recovery.em — locks lexical error reporting and recovery.
// Ember has no `$` or `@` sigil, so a lone one is a lexical error. (A lone `&`/`|`,
// by contrast, are now valid bitwise operators, and `|` also delimits lambdas.) The
// scanner must emit an ERROR token, keep going so it reports every problem in one
// pass, and the run must finish non-zero. The unterminated string is the last line on purpose:
// scanning must hit EOF and report it rather than running off the end.
// Each lexical error now also flows through the diagnostics layer (diag_error), so
// the golden carries a real `file:line:col: error: …` line per problem and the same
// errors appear under `--diagnostics=json` — they used to be invisible to the
// machine-readable stream (OFI-022).
let a = 1 $ 2
let b = 3 @ 4
let s = "unterminated string
