// loop_continue.em — continue skips even i; sums odd 1..9 = 25.
fn main() -> int {
    var i = 0
    var sum = 0
    loop {
        if i >= 10 { break }
        i = i + 1
        if i % 2 == 0 { continue }
        sum = sum + i
    }
    return sum
}
