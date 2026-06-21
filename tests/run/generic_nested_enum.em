// generic_nested_enum.em — regression for OFI-006: substitution recurses through
// an enum instance into a generic struct payload. Option<Box<int>> binds b:Box<int>.
struct Box<T> { value: T }
enum Option<T> { Some(value: T)  None }
fn main() -> int {
    let o: Option<Box<int>> = Some(Box<int> { value: 9 })
    match o {
        case Some(b) { return b.value }
        case None    { return -1 }
    }
    return -1
}
