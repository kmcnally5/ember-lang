// Native backend (M1) differential test: recursion, loop/break/continue, for-range.

fn fib(n: int) -> int {
    if n < 2 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}


fn main() -> int {
    var sum = 0
    var i = 0
    loop {
        if i >= 8 {
            break
        }
        if i % 3 == 0 {
            i = i + 1
            continue
        }
        sum = sum + fib(i)
        i = i + 1
    }
    for k in 1..5 {
        sum = sum + k
    }
    return sum
}
