// match_wildcard.em — `case _` is a catch-all: it matches every variant not named
// by an earlier arm, and makes a match exhaustive without listing them all. A
// `_` inside a variant (`Has(_)`) is an ordinary ignore-binding, not a wildcard.
enum Color { Red  Green  Blue  Cyan  Magenta }

fn rank(c: Color) -> int {
    match c {
        case Red   { return 1 }
        case Green { return 2 }
        case _     { return 10 }      // Blue / Cyan / Magenta
    }
    return 0
}

enum Box { Has(value: int)  Empty }

fn unwrap_or(b: Box) -> int {
    match b {
        case Has(_) { return 100 }    // _ ignores the payload (a binding, not a wildcard)
        case _      { return 0 }      // Empty
    }
    return -1
}

fn main() -> int {
    let r = rank(Red) + rank(Green) + rank(Blue) + rank(Magenta)  // 1 + 2 + 10 + 10 = 23
    let b = unwrap_or(Has(5)) + unwrap_or(Empty)                  // 100 + 0 = 100
    return r + b                                                  // 123
}
