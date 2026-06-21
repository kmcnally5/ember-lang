// conditionals.em — if/else with assignment in branches. x=7; 7>=5 so x=x*2=14.
fn main() -> int {
    var x = 7
    if x >= 5 {
        x = x * 2
    } else {
        x = 0
    }
    return x
}
