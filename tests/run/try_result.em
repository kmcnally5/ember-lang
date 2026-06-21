// try_result.em — `?` unwraps Ok; multiple `?` chain in a single expression.
enum Result<T, E> {
    Ok(value: T)
    Err(error: E)
}
fn checked(n: int) -> Result<int, string> {
    if n < 0 { return Err("negative") }
    return Ok(n)
}
fn sum3(a: int, b: int, c: int) -> Result<int, string> {
    return Ok(checked(a)? + checked(b)? + checked(c)?)
}
fn main() -> int {
    match sum3(1, 2, 3) {
        case Ok(v)  { return v }
        case Err(e) { println(e)  return -1 }
    }
    return -1
}
