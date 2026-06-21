// error_match_nonexhaustive.em — every variant must be handled.
enum E { A  B  C }
fn main() -> int {
    let e = A
    match e {
        case A { return 1 }
        case B { return 2 }
    }
    return 0
}
