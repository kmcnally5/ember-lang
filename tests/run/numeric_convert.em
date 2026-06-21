// numeric_convert.em — explicit int/float conversion. Ember does no implicit
// numeric coercion, so a program crossing int and float converts with the
// to_float / to_int builtins. to_int truncates toward zero. The builtins are the
// bridge that lets an int loop counter feed a floating-point calculation.
fn average(total: int, count: int) -> float {
    return to_float(total) / to_float(count)
}

fn main() -> int {
    let avg = average(7, 2)             // 3.5
    println("avg = {avg}")
    println("to_int(3.9)  = {to_int(3.9)}")        // 3 (toward zero)
    println("to_int(-3.9) = {to_int(0.0 - 3.9)}")  // -3 (toward zero)
    // round-trips and mixing in one expression
    return to_int(to_float(40) + 2.5)              // 42
}
