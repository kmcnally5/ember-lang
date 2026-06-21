// Native backend (M3b) differential test: closures — lambdas, captures, function values,
// and higher-order calls (including generic HOFs over arrays from std/list). A closure is a
// boxed ObjClosure (a lifted-function index + captured values, each refcounted); an indirect
// call splices [captures…, args…] and dispatches through the generated em_invoke trampoline.
import "std/list" as list

fn apply(f: fn(int) -> int, x: int) -> int {
    return f(x)
}

fn twice(f: fn(int) -> int, x: int) -> int {
    return f(f(x))
}

fn inc(n: int) -> int {
    return n + 1
}

fn main() -> int {
    // A plain lambda, a capturing lambda, a bare function value, nested HOF application.
    let add1: fn(int) -> int = |n| n + 1
    let base = 100
    let addbase: fn(int) -> int = |n| n + base
    println("apply {apply(add1, 41)}")
    println("capture {apply(addbase, 5)}")
    println("twice {twice(add1, 10)}")
    println("fnvalue {apply(inc, 7)}")

    // Generic higher-order functions over arrays — generics + closures + arrays composed.
    let xs = [1, 2, 3, 4, 5]
    let doubled = list.map(xs, |n| n * 2)
    let sum = list.reduce(doubled, 0, |acc, x| acc + x)
    let evens = list.filter(xs, |n| n % 2 == 0)
    println("sum {sum}")
    println("evens {evens.len()}")
    return sum + evens.len()
}
