// parallel_sum.em — fan-out/fan-in over a channel. Eight tasks each compute a
// CPU-bound result and `send` it; main `recv`s all eight and sums them. The
// answer is identical whether the runtime runs the tasks cooperatively on one
// thread (serial build) or on real OS threads across cores (EMBER_PARALLEL build)
// — this is the correctness gate for M:N parallelism: same program, same total.
enum Option<T> {
    Some(value: T)
    None
}

fn work(seed: int) -> int {
    var acc = 0
    var i = 0
    loop {
        if i == 50000 { break }
        acc = (acc + i * seed) % 1000003
        i = i + 1
    }
    return acc
}

fn worker(id: int, out: Channel<int>) -> int {
    send(out, work(id + 1))
    return 0
}

fn main() -> int {
    let results: Channel<int> = channel(8)
    nursery {
        spawn worker(0, results)
        spawn worker(1, results)
        spawn worker(2, results)
        spawn worker(3, results)
        spawn worker(4, results)
        spawn worker(5, results)
        spawn worker(6, results)
        spawn worker(7, results)
    }
    var total = 0
    var k = 0
    loop {
        if k == 8 { break }
        match recv(results) {
            case Some(v) { total = total + v }
            case None    { break }
        }
        k = k + 1
    }
    println(total)
    return 0
}
