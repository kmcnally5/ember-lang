// 05_concurrency.em — structured concurrency. The evolution of FROG's async()/channel model.
//
// FROG spawned free-floating goroutines and you manually collected results into arrays:
//     let worker = async(fn() { ... })
//     counts[j] = await(tasks[j])
//
// Ember keeps real concurrency and typed channels, but scopes tasks to a `nursery` block:
//   - `spawn` launches a task INSIDE the nursery.
//   - the nursery block does not exit until every spawned task finishes.
//   - if any task fails, siblings are cancelled safely, and the error surfaces at the block.
//   - no function coloring: a normal `fn` is spawnable; there is no async/sync split.
//   - stack traces stay real and debuggable.
//
// The shape below is a worker pool: one dispatcher feeds chunks of log lines onto a
// jobs channel and closes it; four workers pull chunks in parallel, count the ERROR
// lines, and push each tally onto a results channel; main sums the tallies.

import "std/string" as str

// Count the ERROR lines in one chunk. Pure, borrows its chunk, returns a number.
fn scan(chunk: [string]) -> int {
    var hits = 0
    for line in chunk {
        if str.contains(line, "ERROR") { hits = hits + 1 }
    }
    return hits
}

// Feed a finite batch of chunks, then close the channel so the workers know to stop.
// In a real program these chunks come from read_file(path).split("\n") batched up.
fn dispatch(jobs: Channel<[string]>) {
    send(jobs, ["INFO  start", "ERROR  disk full", "INFO  retry"])
    send(jobs, ["ERROR  auth failed", "ERROR  net timeout", "INFO  ok"])
    send(jobs, ["INFO  done", "INFO  flush"])
    close(jobs)                                  // no more jobs will be sent
}

// Pull chunks until the jobs channel is closed and drained (recv yields None), and
// push a tally per chunk. Several workers share one jobs channel — channels are
// shareable handles, so the chunks fan out across whichever worker is free.
fn worker(jobs: Channel<[string]>, results: Channel<int>) {
    loop {
        match recv(jobs) {
            case Some(chunk) { send(results, scan(chunk)) }
            case None        { break }           // channel closed + drained
        }
    }
}

fn main() {
    let jobs:    Channel<[string]> = channel(200)   // typed channels (FROG had channels untyped)
    let results: Channel<int>      = channel(200)

    // All concurrency lives in this scope. When the block ends, every task is done — guaranteed.
    nursery {
        spawn dispatch(jobs)                  // feeds jobs, then closes the channel
        spawn worker(jobs, results)           // 4 workers, pulling in parallel
        spawn worker(jobs, results)
        spawn worker(jobs, results)
        spawn worker(jobs, results)
    }
    close(results)                            // every worker has finished; safe to close

    var total = 0
    loop {
        match recv(results) {
            case Some(n) { total = total + n }
            case None    { break }
        }
    }
    println("total ERROR lines: {total}")     // 1 + 2 + 0 = 3
}
