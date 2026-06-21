// channel_string_handoff.em — heap objects crossing tasks through a channel. Each
// worker builds fresh heap STRINGS and sends them; a separate task receives and
// drops them. Under the parallel runtime (EMBER_PARALLEL) the sender and receiver
// run on different OS threads, so the receiver frees objects its worker did not
// allocate — the cross-thread path of the per-worker allocator. The answer (total
// bytes received) is identical whether the runtime is serial or parallel: a
// double-free or use-after-free on that path would corrupt the sum or crash.
enum Option<T> {
    Some(value: T)
    None
}

fn build(id: int, out: Channel<string>) -> int {
    var i = 0
    loop {
        if i == 25 {
            break
        }
        let s = "task-{id}-item-{i}"     // a fresh heap string every iteration
        send(out, s)                      // moved into the channel → freed by the receiver
        i = i + 1
    }
    return 0
}

fn drainer(out: Channel<string>, n: int) -> int {
    var bytes = 0
    var got = 0
    loop {
        if got == n {
            break
        }
        match recv(out) {
            case Some(s) {
                bytes = bytes + s.len()   // touch the received string, then drop it
                got = got + 1
            }
            case None {
                break
            }
        }
    }
    println(bytes)
    return 0
}

fn main() -> int {
    let out: Channel<string> = channel(16)
    nursery {
        spawn build(0, out)
        spawn build(1, out)
        spawn build(2, out)
        spawn build(3, out)
        spawn drainer(out, 100)
    }
    return 0
}
