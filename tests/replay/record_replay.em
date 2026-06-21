// record_replay.em — verification loop (§5j) brick 3: deterministic record-replay. The program
// draws random() a FIXED number of times and branches on the values; `--emit=replay` runs it once
// recording those draws (and its output), then again replaying them, and verifies the two runs are
// byte-for-byte identical. The verdict is stable across invocations even though the actual random
// values differ each run — that is the point: a failing run can always be reproduced.
fn main() -> int {
    var hits = 0
    var i = 0
    loop {
        if i >= 5 { break }
        let r = random()
        if r < 0.5 {
            hits = hits + 1
        }
        println("draw {i}: {r}")
        i = i + 1
    }
    println("hits below 0.5: {hits}")
    return hits
}
