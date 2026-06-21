// enum_zero_field.em — zero-field variants constructed bare and matched.
enum Color { Red  Green  Blue }
fn code(c: Color) -> int {
    match c {
        case Red   { return 1 }
        case Green { return 2 }
        case Blue  { return 3 }
    }
    return -1
}
fn main() -> int {
    return code(Green)
}
