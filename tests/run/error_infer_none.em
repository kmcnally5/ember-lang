// error_infer_none.em — a bare None with no annotation cannot infer its type.
enum Option<T> { Some(value: T)  None }
fn main() -> int {
    let x = None
    return 0
}
