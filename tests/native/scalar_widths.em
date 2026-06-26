// OFI-123(b): the NATIVE backend stores a sized numeric LOCAL at its declared width (uint8_t … float)
// instead of a uniform 16-byte Value — reads box it back, writes unbox + truncate. This is a storage
// change only (arithmetic still flows through the width-aware Value ops), so the program behaves
// identically; it runs on BOTH the VM and the native binary and their stdout must match. The cases
// exercise every width, var reassignment, a scalar passed to a function, a scalar in an aggregate,
// and — the boundary that the differential guard caught — a closure CAPTURING a scalar local.

fn add_u8(x: u8, y: u8) -> u32 {
    return u32(x) + u32(y)
}


fn main() {
    // Every integer width as a local.
    let a: i8 = 120
    let b: i16 = 30000
    let c: i32 = 2000000000
    let d: i64 = 9000000000000000000
    let e: u8 = 250
    let f: u16 = 60000
    let g: u32 = 4000000000
    let h: u64 = 18446744073709551615
    println("ints {a} {b} {c} {d} {e} {f} {g} {h}")

    // Floats.
    let p: f32 = 3.5
    let q: f64 = 2.25
    println("floats {p} {q} sum={p + p} {q * q}")

    // var reassignment goes through the unbox-to-width store.
    var i: u8 = 0
    i = e - 50
    i = i + 5
    println("var u8 {i}")

    // A scalar local passed to a function (read boxes it to a Value arg).
    println("call {add_u8(e, 5u8)}")

    // A scalar local inside an aggregate (packed [u8]) and read back.
    let arr: [u8] = [e, i, 7]
    println("arr {arr[0]} {arr[1]} {arr[2]} len={arr.len()}")

    // A closure CAPTURING a scalar local — the boundary case (must box the capture).
    let base: u32 = 100
    let bump: fn(u32) -> u32 = |n| n + base
    println("capture {bump(5)}")
}
