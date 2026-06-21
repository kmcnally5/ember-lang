// spawn_immediate.em — REGRESSION for the spawn-at-spawn-time concurrency model (parallel runtime).
//
// A spawned task must run CONCURRENTLY with the rest of the nursery body, not be deferred to the
// closing brace. Here the worker does a chunk of busy work and then sends a value; meanwhile the
// body polls the channel with the non-blocking `try_recv` until the value arrives. Under the old
// fork-join model the worker did not run until NURSERY_END, so the poll loop never saw a value and
// spun forever — a deadlock. Under spawn-at-spawn-time the worker runs on its own OS thread while
// the body polls, the handoff completes, and the program returns 42.
//
// The result is interleaving-independent (always 42); the harness runs this under a timeout, so a
// regression to fork-join shows up as a TIMEOUT failure rather than a wrong answer.
enum Option<T> {
    Some(value: T)
    None
}




fn worker(ch: Channel<int>) {
    var sum = 0
    for i in 0..2000000 {
        sum = sum + i
    }
    if sum > 0 {
        send(ch, 42)
    }
}




fn main() -> int {
    let ch: Channel<int> = channel(1)
    var got = 0
    nursery {
        spawn worker(ch)
        loop {
            match try_recv(ch) {
                case Some(v) {
                    got = v
                }
                case None {
                }
            }
            if got > 0 {
                break
            }
        }
    }
    return got
}
