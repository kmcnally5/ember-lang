// OFI-046 regression (negative): a `?`-propagated early return is held to the function's
// `ensures` postcondition, just like an explicit `return`. Here the contract forbids an error
// result, so propagating `Err` via `?` must be caught — before the fix it was silently shipped.
enum Result<T, E> {
    Ok(value: T)
    Err(error: E)
}

// The postcondition demands the function never errors out.
fn must_be_ok(r: Result<int, string>) -> bool {
    match r {
        case Ok(v)  { return true }
        case Err(e) { return false }
    }
    return false
}

fn checked(n: int) -> Result<int, string> {
    if n < 0 { return Err("neg") }
    return Ok(n)
}

fn f(a: int, b: int) -> Result<int, string>
    ensures must_be_ok(result)
{
    return Ok(checked(a)? + checked(b)?)   // checked(b)? fires mid-expression -> Err propagates
}

fn main() -> int {
    match f(5, -2) {                        // violates the postcondition on the ? exit
        case Ok(v)  { return v }
        case Err(e) { return 0 }
    }
    return -1
}
