// OFI-046 regression (positive): a function's `ensures` postcondition is checked on the `?`
// (try) propagation exit too, not only on an explicit `return`. The predicate inspects `result`
// on BOTH exits — proving it is bound to the ACTUAL returned value even when `?` fires
// mid-expression (`Ok(a()? + b()?)`), with abandoned temporaries below it on the stack.
enum Result<T, E> {
    Ok(value: T)
    Err(error: E)
}

// Holds on success (value non-negative) AND on the propagated error (message is exactly "neg").
// If `result` were read from the wrong slot, the Err arm would not see "neg" and this would fail.
fn ok_pos_or_neg_msg(r: Result<int, string>) -> bool {
    match r {
        case Ok(v)  { return v >= 0 }
        case Err(e) { return e == "neg" }
    }
    return false
}

fn checked(n: int) -> Result<int, string> {
    if n < 0 { return Err("neg") }
    return Ok(n)
}

fn f(a: int, b: int) -> Result<int, string>
    ensures ok_pos_or_neg_msg(result)
{
    return Ok(checked(a)? + checked(b)?)   // checked(b)? can fire mid-expression
}

fn main() -> int {
    match f(3, 4) {                         // success exit: ensures holds (7 >= 0)
        case Ok(v)  { println("ok {v}") }
        case Err(e) { println("err {e}") }
    }
    match f(5, -2) {                        // ? propagation exit: ensures holds ("neg" == "neg")
        case Ok(v)  { println("ok {v}") }
        case Err(e) { println("err {e}") }
    }
    return 0
}
