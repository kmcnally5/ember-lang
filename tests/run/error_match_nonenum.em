// error_match_nonenum.em — match requires an enum value.
fn main() -> int {
    let x = 5
    match x { case A { return 1 } }
    return 0
}
