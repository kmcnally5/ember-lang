// prelude.em — Option and Result come from the prelude: a program uses Some/None,
// Ok/Err, the `?` operator, and parse_int without declaring either enum itself.
fn safe_div(a: int, b: int) -> Option<int> {
    if b == 0 { return None }
    return Some(a / b)
}

fn checked(n: int) -> Result<int, int> {
    if n < 0 { return Err(0) }
    return Ok(n * 2)
}

fn chain(n: int) -> Result<int, int> {
    let d = checked(n)?              // `?` propagates Err using the prelude Result
    return Ok(d + 1)
}

fn main() -> int {
    var total = 0
    match safe_div(20, 4)  { case Some(v) { total = total + v } case None { } }   // 5
    match "37".parse_int() { case Some(v) { total = total + v } case None { } }   // 37
    match chain(10)        { case Ok(v)   { total = total + v } case Err(e) { } } // 21
    return total                    // 5 + 37 + 21 = 63
}
