// void_fn.em — functions with no `-> T` are unit functions: they run for
// effect and yield no value. A bare `return` is allowed; `fn main()` itself
// may be unit (its implicit result is 0).
fn greet(n: int) {
    println(n)
    return
}

fn tick() {
    println(99)
}

fn main() {
    greet(7)
    tick()
}
