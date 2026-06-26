// error_newtype_not_iterable.em — OFI-149 regression: a newtype's SemType band (NEWTYPE_BASE) sat
// ABOVE SLICE_BASE, and is_slice_type() had no upper bound, so a newtype passed the slice test.
// `for x in u` over an int newtype then ran slice_elem() with an out-of-range index and SEGFAULTED
// the compiler. With the band bounded, this is a clean diagnostic instead of a crash.
type UserId = int
fn main() -> int {
    let u = UserId(5)
    for x in u {
        println("{x}")
    }
    return 0
}
