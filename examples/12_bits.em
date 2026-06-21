// 12_bits.em — bit manipulation. The `& | ^ ~ << >>` operators are what let Ember
// write real systems code — hashing, PRNGs, bit flags, codecs — in Ember itself,
// rather than calling down into C for every primitive.
//
// Two demonstrations: a xorshift PRNG (pure shift + xor, no library, no
// wrapping-multiply) and Unix-style permission flags packed into one byte.

// xorshift64 — a tiny, fast pseudo-random generator. Each step scrambles the state
// with three shift-and-xor rounds. On u64 the shifts wrap within 64 bits and xor
// never overflows, so the whole thing is total and deterministic.
fn xorshift64(state: u64) -> u64 {
    var x = state
    x = x ^ (x << 13)
    x = x ^ (x >> 7)
    x = x ^ (x << 17)
    return x
}


// Flags packed into a byte, tested and set with masks — the bread and butter of
// protocols, file modes, and hardware registers.
fn main() -> int {
    // PRNG: advance from a fixed seed. Same seed → same sequence, every run.
    var s: u64 = 88172645463325252
    s = xorshift64(s)
    let first = s
    s = xorshift64(s)
    println("xorshift step 1: {first}")
    println("xorshift step 2: {s}")

    // Permission bits: read = 1, write = 2, exec = 4.
    let read:  u8 = 1
    let write: u8 = 2
    let exec:  u8 = 4

    var perms: u8 = 0
    perms = perms | read | write          // grant read + write
    let can_write = (perms & write) != 0  // true
    let can_exec  = (perms & exec) != 0   // false

    // ~ clears bits: revoke write by AND-ing with its complement.
    perms = perms & ~write
    let still_write = (perms & write) != 0   // false now

    // Return a small checksum of the booleans so the example has a definite result.
    var result = 0
    if can_write    { result = result + 1 }
    if can_exec     { result = result + 10 }
    if still_write  { result = result + 100 }
    return result                          // can_write only → 1
}
