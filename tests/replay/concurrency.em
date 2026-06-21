// concurrency.em — verification loop (§5j) brick 3: record-replay runs in the deterministic serial
// scheduler, so a structured-concurrency program (nursery/spawn/channels) with per-task random()
// replays byte-for-byte — the task interleaving is fixed, so the recorded draws line up exactly.
fn produce(out: Channel<int>, base: int) {
    var i = 0
    loop {
        if i >= 3 { break }
        let r = random()
        var v = base + i
        if r < 0.5 { v = v + 100 }
        send(out, v)
        i = i + 1
    }
}


fn main() -> int {
    let ch: Channel<int> = channel(16)
    var total = 0
    nursery {
        spawn produce(ch, 0)
        spawn produce(ch, 10)
    }
    var k = 0
    loop {
        if k >= 6 { break }
        match recv(ch) {
            case Some(v) { total = total + v  println("got {v}") }
            case None    { break }
        }
        k = k + 1
    }
    println("total {total}")
    return total
}
