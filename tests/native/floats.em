// Native backend (M1) differential test: f64 arithmetic through a call + a loop.

fn area(r: f64) -> f64 {
    return r * r * 3.14159
}


fn main() -> f64 {
    var total = 0.0
    for i in 0..3 {
        total = total + area(2.0)
    }
    return total - 0.5
}
