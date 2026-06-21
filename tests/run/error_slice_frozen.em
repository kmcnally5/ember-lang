// error_slice_frozen.em — while a slice borrows an array, the array is frozen: mutating it
// (here, append) would realloc the buffer and dangle the view, so it is a compile error.
fn main() -> int {
    var a = [1, 2, 3]
    let s = a[0..2]
    a.append(4)
    return s[0]
}
