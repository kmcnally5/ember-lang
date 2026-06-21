// error_channel_untyped.em — channel(N) needs a Channel<T> type to infer from.
fn main() -> int {
    let c = channel(4)
    return 0
}
