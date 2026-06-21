// error_channel_deadlock.em — a task waits on a channel no one fills and no one
// closes. recv would block forever (close would instead hand back None), so the
// scheduler reports a deadlock.
enum Option<T> {
    Some(value: T)
    None
}

fn waiter(ch: Channel<int>) -> Option<int> {
    return recv(ch)
}

fn main() -> int {
    let ch: Channel<int> = channel(1)
    nursery {
        spawn waiter(ch)
    }
    return 0
}
