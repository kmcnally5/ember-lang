// declarations.em — locks every top-level declaration form: import, global
// let/var, interface signatures, generic struct with a method, enum with
// data-carrying and zero-field variants, and a free function.

import "std/io" as io

let GREETING = "hi"
var counter = 0

interface Show {
    fn show(self) -> string
}

struct Pair<A, B> implements Show {
    first: A
    second: B

    fn swap(mut self) {
        return
    }
}

enum Color {
    Rgb(r: int, g: int, b: int)
    Named(name: string)
    Transparent
}

fn add(a: int, b: int) -> int {
    return a + b
}
