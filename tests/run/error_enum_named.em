// OFI-140: named enum-variant construction validates the field names — this locks the diagnostics for
// a misspelled name, a duplicate, an incomplete set, mixing positional+named, and named args on a
// (non-variant) function call. Each is its own compile error (the file fails to compile).

enum E {
    V(a: int, b: int)
}


fn f(x: int) -> int {
    return x
}


fn main() {
    let _ = V(a: 1, c: 2)        // no such field 'c'
    let _ = V(a: 1, a: 2)        // 'a' set twice
    let _ = V(a: 1)              // missing 'b'
    let _ = V(a: 1, 2)           // mixed positional + named
    let _ = f(x: 5)              // named arg on a function call
}
