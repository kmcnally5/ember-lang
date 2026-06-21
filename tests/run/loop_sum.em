// loop_sum.em — loop + if + break: sum of 0..4 = 10.
fn main() -> int {
    var i = 0
    var sum = 0
    loop {
        if i >= 5 { break }
        sum = sum + i
        i = i + 1
    }
    return sum
}
