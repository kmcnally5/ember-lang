// sized_int_aggregates.em — sized integers as struct fields and array elements,
// in comparisons, and rendered by interpolation. A `[u8]`/`[i32]` annotation
// guides bare-literal elements to the right width.
struct Pixel { r: u8  g: u8  b: u8 }

fn brightness(p: Pixel) -> i32 {
    return i32(p.r) + i32(p.g) + i32(p.b)     // widen bytes to sum without overflow
}

fn main() -> int {
    let p = Pixel { r: 255, g: 128, b: 0 }
    let xs: [i32] = [10, 20, 30]              // literal elements adopt i32
    var i = 0
    var total: i32 = 0
    loop {
        if i == xs.len() { break }
        total = total + xs[i]
        i = i + 1
    }
    if p.r > p.g { println("r={p.r} g={p.g}") }  // u8 compare + interpolation
    return i64(brightness(p)) + i64(total)        // 383 + 60 = 443
}
