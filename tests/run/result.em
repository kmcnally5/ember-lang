// result.em — Result<T, E>: Ok infers T from its argument, E from the annotation.
enum Result<T, E> {
    Ok(value: T)
    Err(error: E)
}
fn describe(r: Result<int, string>) -> int {
    match r {
        case Ok(v)  { return v }
        case Err(e) { println(e)  return -1 }
    }
    return -1
}
fn main() -> int {
    let good: Result<int, string> = Ok(7)
    let bad:  Result<int, string> = Err("nope")
    return describe(good) + describe(bad)
}
