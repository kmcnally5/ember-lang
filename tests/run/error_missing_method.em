// error_missing_method.em — implementing an interface without its method is an error.
interface Ord { fn compare(self, other: Self) -> int }
struct V implements Ord { n: int }
fn main() -> int { return 0 }
