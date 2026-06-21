// logical.em — short-circuit && / || and comparisons. 5>0 && 5<10 is true.
fn main() -> int {
    let a = 5
    if a > 0 && a < 10 || false {
        return 1
    }
    return 0
}
