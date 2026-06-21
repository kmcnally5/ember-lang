// generic_fn_infer.em — inference through nested generics: unify Box<T> against
// the Box<int> argument, and Option<T> against the expected return type.
struct Box<T> { value: T }
enum Option<T> { Some(value: T)  None }
fn unwrap<T>(b: Box<T>) -> T { return b.value }
fn none_of<T>() -> Option<T> { return None }
fn main() -> int {
    let n: Option<int> = none_of()
    match n {
        case Some(v) { return v }
        case None    { return unwrap(Box<int> { value: 4 }) }
    }
    return -1
}
