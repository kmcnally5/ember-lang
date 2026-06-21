// for_indexed.em — native differential test (OFI-054): the indexed for-loop `for (i, x) in arr`
// binds the 0-based element index alongside the element. Covers an int array, a string array
// (index used as int, element as string), and capturing both the index and element in a lambda.
fn apply(f: fn(int) -> int, n: int) -> int {
    return f(n)
}

fn main() -> int {
    let xs = [10, 20, 30, 40]
    var acc = 0
    for (i, x) in xs {
        acc = acc + i * 100 + x           // (0+10)+(100+20)+(200+30)+(300+40) = 700
    }

    let words = ["a", "bb", "ccc"]
    var ls = 0
    for (i, w) in words {
        ls = ls + i + w.len()             // (0+1)+(1+2)+(2+3) = 9
    }

    var ec = 0
    for (i, x) in xs {
        ec = ec + apply(|n| n + i + x, 0) // (0+10)+(1+20)+(2+30)+(3+40) = 106
    }

    return acc + ls + ec                  // 700 + 9 + 106 = 815
}
