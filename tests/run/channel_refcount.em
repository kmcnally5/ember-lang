// channel_refcount.em — exercises channel reference counting (the fix that made Channel<T> a
// refcounted shareable handle so it is reclaimed at the last drop instead of leaking to exit).
// Three lifecycle shapes, all deterministic on BOTH the serial and parallel runtimes:
//   1. a channel SHARED by two spawned producers — each holds a counted reference, dropped when
//      its task ends; the parent's binding holds the last reference and reclaims it,
//   2. a channel RETURNED from a function — it escapes its creating scope without an early drop,
//   3. an ABANDONED channel left holding an undrained buffered value — the buffered value (and the
//      channel) are reclaimed at the channel's last drop, not leaked.
// The leak this guards is RSS-only (the runtime would still produce the right answer while
// leaking), so the assertion here is the returned total; the no-leak property is covered by the
// ASan + RSS probes. Result: 10 + 20 + 100 = 130.
enum Option<T> {
    Some(value: T)
    None
}




fn producer(ch: Channel<int>, v: int) {
    send(ch, v)
}




fn make_ch() -> Channel<int> {
    let ch: Channel<int> = channel(1)
    send(ch, 100)
    return ch
}




fn main() -> int {
    var total = 0
    // (1) shared channel: two producers each hold a counted reference to `shared`.
    let shared: Channel<int> = channel(2)
    nursery {
        spawn producer(shared, 10)
        spawn producer(shared, 20)
    }
    match recv(shared) {
        case Some(v) {
            total = total + v
        }
        case None {
        }
    }
    match recv(shared) {
        case Some(v) {
            total = total + v
        }
        case None {
        }
    }
    // (2) returned channel: `make_ch` hands ownership out without dropping it at its scope exit.
    let c: Channel<int> = make_ch()
    match recv(c) {
        case Some(v) {
            total = total + v
        }
        case None {
        }
    }
    // (3) abandoned channel with a buffered, never-received value — reclaimed at scope exit.
    let dead: Channel<int> = channel(1)
    send(dead, 5)
    return total
}
