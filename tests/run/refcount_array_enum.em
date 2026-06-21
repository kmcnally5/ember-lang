// refcount_array_enum.em — an array is a uniquely-owned, mutable aggregate (a
// move type, like a struct): it is freed at scope exit, recursively releasing its
// elements — so an array of strings drops each string's reference. An enum is an
// immutable shared value, so it is reference-counted: aliasing one bumps the count
// and the last owner frees it (releasing its payload string). Every value here is
// read live right up to the final concatenation — an early free would corrupt it.
enum Box { Of(value: string)  Empty }

fn unwrap(b: Box) -> string {
    match b {
        case Of(s) { return s }       // returns the payload string (an alias)
        case Empty { return "none" }
    }
    return "x"
}

fn main() -> string {
    let words = ["a", "b"]            // an array of strings (uniquely owned)
    let boxed = Of("z")               // an enum carrying a string
    let same = boxed                  // alias the enum (refcount up)
    let got = unwrap(same)            // pull the payload string back out
    return words[0] + words[1] + got  // => abz
}
