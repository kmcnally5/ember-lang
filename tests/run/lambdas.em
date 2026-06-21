// lambdas.em — closures: |params| expr / |params| { block }, lifted to real
// functions, capturing enclosing variables by value. Covers no-capture, single and
// multiple captures, a block body, a closure invoked more than once (capture reused),
// a refcounted (string) capture, shadowing (an inner binding is not mis-captured),
// and the annotated-let form.
fn apply(f: fn(int) -> int, x: int) -> int { return f(x) }
fn each(f: fn(int) -> int, a: int, b: int) -> int { return f(a) + f(b) }
fn smap(f: fn(string) -> string, s: string) -> string { return f(s) }
fn main() -> int {
    let a = apply(|x| x * 2, 5)                          // 10  (no capture)
    let n = 100
    let b = apply(|x| x + n, 5)                          // 105 (captures n)
    let tw = each(|x| x + n, 1, 2)                       // (1+100)+(2+100)=203 (reused)
    let sq = apply(|x| { let y = x * x  return y }, 4)   // 16  (block body)
    let suffix = "!"
    let r = smap(|s| s + suffix, "hi")                   // "hi!" (refcounted capture)
    var sbonus = 0
    if r == "hi!" { sbonus = 1 }
    let shadow = apply(|x| { let n = x + 1  return n }, 5)   // 6 (inner n shadows; 100 not captured)
    let g: fn(int) -> int = |x| x - 1                    // annotated-let form
    let gv = g(10)                                       // 9
    return a + b + tw + sq + sbonus + shadow + gv        // 10+105+203+16+1+6+9 = 350
}
