// refcount_channel.em — reference-counted values flow correctly through channels.
// A worker receives strings, passes some straight through and transforms others,
// and the `recv` results (fresh Option temporaries) are released at each match.
// `send` of a received payload bumps its refcount so it survives into the second
// channel, balanced against the match-subject release — if that balance were off,
// the strings would be freed mid-flight and the final result would be corrupt.
enum Option<T> { Some(value: T)  None }

fn worker(jobs: Channel<string>, out: Channel<string>) {
    loop {
        match recv(jobs) {
            case Some(s) { send(out, s) }      // pass the received string straight on
            case None    { break }
        }
    }
}

fn main() -> string {
    let jobs: Channel<string> = channel(4)
    let out: Channel<string> = channel(4)
    nursery {
        spawn worker(jobs, out)
        send(jobs, "ab")
        send(jobs, "cd")
        send(jobs, "ef")
        close(jobs)
    }
    var r = ""
    match recv(out) { case Some(a) { r = a } case None { } }
    match recv(out) { case Some(b) { r = r + b } case None { } }
    match recv(out) { case Some(c) { r = r + c } case None { } }
    return r                                    // => abcdef
}
