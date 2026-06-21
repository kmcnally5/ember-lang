// tests/run/error_send_closed.em — OFI-086: sending on a CLOSED channel is a programming error
// (like Go's panic, and consistent with Ember's other programming-error traps — overflow, bounds).
// All three runtimes (serial / 1:1 parallel / M:N) report it; this golden pins the serial one.
fn main() -> int {
    let ch: Channel<int> = channel(2)
    close(ch)
    send(ch, 7)              // closed → "send on a closed channel", never reaches below
    print("unreachable\n")
    return 0
}
