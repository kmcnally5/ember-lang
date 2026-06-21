// for_enumerate.em — `for (i, x) in array` (index + element together), and the
// fix for capturing a for-loop variable or body local in a lambda (the hidden
// array/index/length slots codegen uses now line up with the checker's, so a
// closure's recorded capture slots are correct). Capture inside a for body used to
// crash or read the wrong slot.
fn apply(f: fn(int) -> int, v: int) -> int { return f(v) }
fn main() -> int {
    var pass = 0

    // enumerate: i is the index (0,1,2,3), x the element
    let xs = [10, 20, 30, 40]
    var acc = 0
    for (i, x) in xs { acc = acc + i * 100 + x }   // 10 + 120 + 230 + 340 = 700
    if acc == 700 { pass = pass + 1 }              // 1

    // enumerate over strings
    let words = ["a", "bb", "ccc"]
    var ls = 0
    for (i, w) in words { ls = ls + i + w.len() }  // (0+1)+(1+2)+(2+3) = 9
    if ls == 9 { pass = pass + 1 }                 // 2

    // capture the (array) loop variable in a lambda
    var cap = 0
    for x in xs {
        cap = cap + apply(|n| n + x, 1000)         // 1010+1020+1030+1040 = 4100
    }
    if cap == 4100 { pass = pass + 1 }             // 3

    // capture the range loop variable AND a body local
    var rc = 0
    for i in 0..3 {
        let base = i * 1000
        rc = rc + apply(|n| n + base + i, 1)       // 1 + 1002 + 2003 = 3006
    }
    if rc == 3006 { pass = pass + 1 }              // 4

    // capture the enumerate index + element together
    var ec = 0
    for (i, x) in xs {
        ec = ec + apply(|n| n + i + x, 0)          // (0+10)+(1+20)+(2+30)+(3+40)=106
    }
    if ec == 106 { pass = pass + 1 }               // 5

    println("pass={pass}/5")
    return pass                                    // 5
}
