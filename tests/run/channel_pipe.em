// channel_pipe.em — producer/consumer over a buffered channel. The buffer (2) is
// smaller than the number of items (3), so send blocks and the scheduler
// interleaves the two tasks cooperatively (green threads). recv yields Option<T>
// (Some while values flow), so the consumer unwraps each receive.
enum Option<T> {
    Some(value: T)
    None
}

fn producer(ch: Channel<int>) -> int {
    send(ch, 10)
    send(ch, 20)
    send(ch, 30)
    return 0
}

fn take(ch: Channel<int>) -> int {
    match recv(ch) {
        case Some(v) { return v }
        case None    { return 0 }
    }
    return 0
}

fn consumer(ch: Channel<int>) -> int {
    println(take(ch) + take(ch) + take(ch))   // 10 + 20 + 30 = 60
    return 0
}

fn main() -> int {
    let ch: Channel<int> = channel(2)
    nursery {
        spawn producer(ch)
        spawn consumer(ch)
    }
    return 0
}
