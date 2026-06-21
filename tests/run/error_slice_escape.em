// error_slice_escape.em — a Slice<T> is a borrowed view; it cannot be returned (it would
// outlive the array it borrows). The fix is to return an owned copy with .slice(lo, hi).
fn head(a: [int]) -> Slice<int> {
    return a[0..2]
}
fn main() -> int { return 0 }
