// channel_refcount.em (parallel variant) — stresses the CROSS-THREAD half of channel reference
// counting, which the serial golden (tests/run/channel_refcount.em) cannot reach. Eight producers
// run on real OS threads, all sharing ONE channel: each holds a counted reference and drops it on
// a non-home thread when its task ends, while the parent (the channel's home) holds the last
// reference and reclaims the channel + its OS primitives only after every worker has joined. This
// is the home/non-home reclaim path flagged as the fix's biggest risk; a refcount slip would show
// as an ASan use-after-free or a double-free here. The result is interleaving-independent: the
// eight values 1..8 are produced concurrently and summed after the join → 36.
enum Option<T> {
    Some(value: T)
    None
}




fn producer(ch: Channel<int>, v: int) {
    send(ch, v)
}




fn main() -> int {
    let ch: Channel<int> = channel(8)
    nursery {
        spawn producer(ch, 1)
        spawn producer(ch, 2)
        spawn producer(ch, 3)
        spawn producer(ch, 4)
        spawn producer(ch, 5)
        spawn producer(ch, 6)
        spawn producer(ch, 7)
        spawn producer(ch, 8)
    }
    var total = 0
    for i in 0..8 {
        match recv(ch) {
            case Some(v) {
                total = total + v
            }
            case None {
            }
        }
    }
    return total
}
