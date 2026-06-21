// math_bench.em — exercises Ember's arithmetic and doubles as a speed benchmark.
//
// Covers: recursion (Fibonacci, factorial), iterative loops, integer division
// and modulo (GCD, primality, Collatz), fast exponentiation, and floating-point
// series (a Leibniz approximation of pi and a Newton square root). All integer
// results stay within Ember's checked 64-bit range — overflow traps rather than
// wrapping, so the values are chosen to fit (fib up to 92, factorial up to 20).
//
// The naive recursive Fibonacci at the end dominates runtime; time the whole run:
//     time ./build/emberc --emit=run benchmarks/math_bench.em


// ---- Recursion ----

fn fib_rec(n: int) -> int {
    if n < 2 { return n }
    return fib_rec(n - 1) + fib_rec(n - 2)
}


fn fib_iter(n: int) -> int {
    var a = 0
    var b = 1
    var i = 0
    loop {
        if i == n { return a }
        let next = a + b
        a = b
        b = next
        i = i + 1
    }
    return a
}


fn factorial(n: int) -> int {
    if n < 2 { return 1 }
    return n * factorial(n - 1)
}


// ---- Integer number theory ----

fn gcd(a: int, b: int) -> int {
    var x = a
    var y = b
    loop {
        if y == 0 { return x }
        let r = x % y
        x = y
        y = r
    }
    return x
}


fn is_prime(n: int) -> bool {
    if n < 2 { return false }
    var d = 2
    loop {
        if d * d > n { return true }
        if n % d == 0 { return false }
        d = d + 1
    }
    return true
}


fn count_primes(limit: int) -> int {
    var count = 0
    var n = 2
    loop {
        if n >= limit { return count }
        if is_prime(n) { count = count + 1 }
        n = n + 1
    }
    return count
}


fn collatz_steps(start: int) -> int {
    var n = start
    var steps = 0
    loop {
        if n == 1 { return steps }
        if n % 2 == 0 { n = n / 2 } else { n = 3 * n + 1 }
        steps = steps + 1
    }
    return steps
}


fn ipow(base: int, exp: int) -> int {          // fast (binary) exponentiation
    var result = 1
    var b = base
    var e = exp
    loop {
        if e % 2 == 1 { result = result * b }
        e = e / 2
        if e == 0 { return result }             // stop before squaring `b` again,
        b = b * b                               // so the final square can't overflow
    }
    return result
}


// ---- Floating point ----

fn pi_leibniz(terms: int) -> float {            // 4 * (1 - 1/3 + 1/5 - 1/7 + ...)
    var sum = 0.0
    var sign = 1.0
    var k = 0
    loop {
        if k == terms { return sum * 4.0 }
        let denom = 2.0 * to_float(k) + 1.0     // int loop counter → float term
        sum = sum + sign / denom
        sign = 0.0 - sign                       // flip the sign each term
        k = k + 1
    }
    return sum * 4.0
}


fn sqrt_newton(x: float) -> float {             // Newton-Raphson iteration
    if x <= 0.0 { return 0.0 }
    var guess = x
    var i = 0
    loop {
        if i == 40 { return guess }
        guess = (guess + x / guess) / 2.0
        i = i + 1
    }
    return guess
}


fn main() -> int {
    println("=== Ember math benchmark ===")

    // Recursion
    println("fib_rec(30)    = {fib_rec(30)}")          // 832040
    println("fib_iter(90)   = {fib_iter(90)}")         // 2880067194370816120
    println("factorial(20)  = {factorial(20)}")        // 2432902008176640000

    // Integer number theory
    println("gcd(1071, 462) = {gcd(1071, 462)}")       // 21
    println("primes < 10000 = {count_primes(10000)}")  // 1229
    println("collatz(27)    = {collatz_steps(27)}")    // 111 steps
    println("ipow(2, 40)    = {ipow(2, 40)}")          // 1099511627776

    // Floating point
    println("pi ~ {pi_leibniz(1000000)}")              // ~3.14159...
    println("sqrt(2) ~ {sqrt_newton(2.0)}")            // ~1.41421...

    // Heavy load, self-timed with the monotonic clock() — naive recursive
    // Fibonacci (~30M calls). Reports its own wall-clock cost in seconds.
    let start = clock()
    let result = fib_rec(35)                           // 9227465
    let elapsed = clock() - start
    println("fib_rec(35)    = {result}  ({elapsed}s)")

    return 0
}
