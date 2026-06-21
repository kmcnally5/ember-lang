// channel_close.em — the worker-pool idiom: a producer sends a finite batch then
// close()s the channel; the consumer loops on recv until it sees None (the
// channel is closed and drained) and breaks. recv yields Option<T>, so absence is
// an ordinary matched value, not a control-flow signal. Producer and consumer are
// void functions — they run for effect.
enum Option<T> {
    Some(value: T)
    None
}

fn producer(ch: Channel<int>) {
    send(ch, 10)
    send(ch, 20)
    send(ch, 30)
    close(ch)                       // no more values will be sent
}

fn consumer(ch: Channel<int>, out: Channel<int>) {
    var sum = 0
    loop {
        match recv(ch) {
            case Some(v) { sum = sum + v }
            case None    { break }      // closed + drained
        }
    }
    send(out, sum)
}

fn main() -> int {
    let jobs: Channel<int> = channel(4)
    let out: Channel<int> = channel(1)
    nursery {
        spawn producer(jobs)
        spawn consumer(jobs, out)
    }
    match recv(out) {
        case Some(v) { return v }       // => 60
        case None    { return 0 }
    }
    return 0
}
