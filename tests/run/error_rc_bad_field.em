// An `rc struct` is deeply immutable and shared, so every field must itself be immutably shareable
// (R3, the formation whitelist). An array field could carry a mutable interior into the shared value
// (and re-open reference cycles), so it is rejected at the declaration.
rc struct Bag {
    items: [int]
}

fn main() -> int {
    return 0
}
