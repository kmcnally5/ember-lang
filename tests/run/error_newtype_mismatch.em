// error_newtype_mismatch.em — OFI-149: passing an OrderId where a UserId is expected is a compile
// error even though both erase to int. This is the nominal distinctness that kills argument/unit
// confusion (a top LLM-codegen bug class).
type UserId = int
type OrderId = int

fn greet(u: UserId) -> int {
    return 0
}

fn main() -> int {
    return greet(OrderId(3))
}
