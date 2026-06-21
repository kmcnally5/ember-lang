// An `rc struct` is deeply immutable: a write THROUGH an rc value must be rejected even when it is
// reached via a mutable (`var`) NON-rc container. This is the laundering hole the adversarial design
// caught — the mutation gate must check every path step's type, not just the root binding's `var`-ness
// (R4). `h` is a mutable Holder, but `h.cfg` is a shared, immutable rc value, so `h.cfg.port = ...`
// would mutate a value other owners can see — a compile error.
rc struct Config {
    port: int
}

struct Holder {
    cfg: Config
    tag: int
}

fn main() -> int {
    var h = Holder { cfg: Config { port: 80 }, tag: 1 }
    h.cfg.port = 9090
    return h.cfg.port
}
