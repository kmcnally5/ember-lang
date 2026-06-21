// error_dup_case.em — a variant may be matched at most once.
enum E { A  B }
fn main() -> int {
    let e = A
    match e {
        case A { return 1 }
        case A { return 2 }
        case B { return 3 }
    }
    return 0
}
