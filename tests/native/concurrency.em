// Native backend (M4) differential test: structured concurrency — nursery + spawn + typed
// channels on real OS threads. A producer fills a jobs channel and closes it; four workers
// pull jobs in parallel, square each, and push to a results channel; main sums the results.
// The total is order-independent, so the threaded native run matches the (cooperative) VM.
fn worker(jobs: Channel<int>, results: Channel<int>) {
    loop {
        match recv(jobs) {
            case Some(j) { send(results, j * j) }
            case None    { break }
        }
    }
}

fn main() -> int {
    let jobs: Channel<int> = channel(100)
    let results: Channel<int> = channel(100)
    var i = 0
    loop {
        if i == 20 { break }
        send(jobs, i)
        i = i + 1
    }
    close(jobs)
    nursery {
        spawn worker(jobs, results)
        spawn worker(jobs, results)
        spawn worker(jobs, results)
        spawn worker(jobs, results)
    }
    close(results)
    var total = 0
    loop {
        match recv(results) {
            case Some(n) { total = total + n }
            case None    { break }
        }
    }
    println("sum of squares {total}")
    return total
}
