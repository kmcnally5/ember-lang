// typed_arrays.em — arrays of scalar elements are stored in *packed* native
// buffers (a [u8] is bytes, an [i32] is int32s, a [u64]/[f64] is 8-byte slots),
// so reading boxes the element back to a value and writing truncates/rounds to
// the element width. Arrays of heap objects ([string]) stay boxed. Exercises
// index, set, append, pop, and iteration across widths.
fn sum_bytes(xs: [u8]) -> i32 {
    var total: i32 = 0
    var i = 0
    loop {
        if i == xs.len() { break }
        total = total + i32(xs[i])
        i = i + 1
    }
    return total
}

fn main() -> int {
    var bytes: [u8] = [10, 20, 30]
    bytes.append(40)            // literal adopts u8
    bytes[0] = 100              // set adopts u8
    let bsum = sum_bytes(bytes)  // 100+20+30+40 = 190

    var big: [u64] = [9000000000000000000]
    big[0] = big[0] + big[0]    // 1.8e19 — packed 8-byte slot holds it unsigned
    let last = big[0] / 3        // unsigned divide

    let reals: [f32] = [1.5, 2.5]
    let r = reals[0] + reals[1]  // 4.0 (f32, packed 4-byte)

    let words: [string] = ["x", "yy"]    // boxed array still works
    println("{bsum} {last} {words[1]} {to_int(r)}")
    return i64(bsum)             // 190
}
