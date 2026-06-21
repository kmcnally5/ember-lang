// token_coverage.em — exercises every Ember token so the lexer has a single
// regression anchor for the whole token set. This need not be semantically
// valid Ember; it only has to tokenize. If a keyword or operator is ever added,
// removed, or renamed, this case's golden output changes and the suite flags it.

import "std/io" as io

interface Eq {
    fn eq(self, other: Self) -> bool
}

struct Box<T> {
    value: T
}

enum Tri { A B C }

fn cover(mut self, x: int, move y: float) -> bool {
    let a = 1 + 2 - 3 * 4 / 5 % 6
    var b = a == 1 && a != 2 || !true
    if a <= 3 { return false } else { return b >= 9 }

    loop {
        for i in [1, 2, 3] {
            if i < 2 { continue }
            if i > 2 { break }
        }
    }

    match x {
        case A { spawn cover(self, 0, 0.0) }
        case B { nursery { } }
        case C { return io.read()? }
    }
}
