// error_sig_mismatch.em — the method exists but its signature (return type) does
// not match the interface's.
interface Ord { fn compare(self, other: Self) -> int }
struct V implements Ord {
    n: int
    fn compare(self, other: V) -> bool { return true }
}
fn main() -> int { return 0 }
