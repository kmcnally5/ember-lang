// recursion_fib.em — recursion (and forward/self reference). fib(10) = 55.
fn fib(n: int) -> int {
    if n < 2 { return n }
    return fib(n - 1) + fib(n - 2)
}
fn main() -> int {
    return fib(10)
}
