// try_recv.em — the non-blocking channel poll. try_recv(ch) returns Some(v) if a value is queued
// right now, else None — WITHOUT blocking (the blocking recv would hang the serial runtime here on
// an empty channel, which is exactly what an event loop must avoid). Deterministic, no concurrency:
// two queued values come back as Some, then an empty (and a closed-empty) channel returns None.
enum Option<T> {
    Some(value: T)
    None
}






fn main() -> int {
    let ch: Channel<int> = channel(4)
    send(ch, 10)
    send(ch, 20)
    var out = 0
    match try_recv(ch) {        // queued -> Some(10)
        case Some(v) {
            out = out + v
        }
        case None {
            out = out - 100
        }
    }
    match try_recv(ch) {        // queued -> Some(20)
        case Some(v) {
            out = out + v
        }
        case None {
            out = out - 100
        }
    }
    match try_recv(ch) {        // empty, open -> None (must NOT block)
        case Some(v) {
            out = out + v
        }
        case None {
            out = out - 1
        }
    }
    close(ch)
    match try_recv(ch) {        // empty, closed -> None
        case Some(v) {
            out = out + v
        }
        case None {
            out = out - 1
        }
    }
    return out                  // 10 + 20 - 1 - 1 = 28
}
