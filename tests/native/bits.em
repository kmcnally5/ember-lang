// Native backend (M1) differential test: width-aware bitwise ops and shifts (i32).

fn main() -> i32 {
    let a: i32 = 3855
    let b: i32 = 255
    let c = (a & b) | (a ^ b)
    let d = c << 2
    return (d >> 1) | 1
}
