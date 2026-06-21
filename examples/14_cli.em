// 14_cli.em — a real command-line program. Ember can now read the arguments it was
// launched with (`args()`), consult the environment (`env()`), and set an exit code
// (`exit()`) — the basics every CLI tool needs.
//
// Run it:   emberc --emit=run examples/14_cli.em Ada Grace
//           GREETING=Hi emberc --emit=run examples/14_cli.em Ada
//
// With no names it prints usage and exits non-zero, like a well-behaved tool.

import "std/string" as str


fn main() {
    let names = args()                  // everything after the source file

    if names.len() == 0 {
        println("usage: greet <name>...")
        exit(1)                         // nothing to do — fail cleanly
    }

    // The greeting word is configurable via the environment, defaulting to "Hello".
    var word = env("GREETING")
    if word == "" {
        word = "Hello"
    }

    // Greet each name. `concat` joins without the O(n^2) of repeated `+`.
    for name in names {
        println(concat([word, ", ", name, "!"]))
    }

    println("(greeted {names.len()} {noun(names.len())})")
}


// A tiny pluraliser, just to do some real work with the count.
fn noun(n: int) -> string {
    if n == 1 { return "person" }
    return "people"
}
