// OFI-049: a `Ptr` is a linear handle with no destructor, so it may not be STORED in an aggregate (a
// struct field here, but also an array/enum/channel/generic), where the close obligation would be
// silently lost. Rejected at type formation — the only guard that survives generic erasure.
struct Conn { handle: Ptr }
fn main() -> int { return 0 }
