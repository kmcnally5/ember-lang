// try_option.em — `?` on Option unwraps Some or returns None early.
enum Option<T> { Some(value: T)  None }
fn plus_one(o: Option<int>) -> Option<int> {
    let v = o?
    return Some(v + 1)
}
fn main() -> int {
    let a: Option<int> = Some(41)
    match plus_one(a) {
        case Some(v) { return v }
        case None    { return -1 }
    }
    return -1
}
