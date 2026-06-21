// parallel_bench.em — a stress suite for Ember's structured concurrency.
//
// Every section is written ONCE with nursery/spawn/channel. Run it under the serial
// compiler (cooperative green threads, one core) and under the parallel compiler
// (-DEMBER_PARALLEL=1, real OS threads on every core) and compare the per-section
// wall-clock — the ratio is the true parallel speedup of that exact program. Each
// section prints `SECTION <name> <checksum> <ms>`; the checksum is deterministic, so
// the serial and parallel runs must agree (a parallelism bug shows as a mismatch),
// and `benchmarks/parbench.sh` pairs the two runs into a speedup table.
//
// The workloads span the axes that decide how good a parallel runtime is:
//   montecarlo — embarrassingly-parallel float compute  (raw core scaling, best case)
//   primes     — independent integer compute             (real-world compute)
//   alloc      — per-task small-object churn             (per-worker allocator scaling)
//   pipe       — build heap strings, hand them to a collector (cross-thread free + channels)
//   nested     — recursive divide & conquer              (nested nurseries / thread-per-fiber)

enum Option<T> {
    Some(value: T)
    None
}






// ---- timing + reduction helpers ------------------------------------------------

fn ms_since(t0: float) -> int {
    return to_int((clock() - t0) * 1000.0)
}






// Drain `n` integer results from a channel and sum them (mod nothing — caller's job).
fn collect(ch: Channel<int>, n: int) -> int {
    var total = 0
    var got = 0
    loop {
        if got == n {
            break
        }
        match recv(ch) {
            case Some(v) { total = total + v }
            case None    { break }
        }
        got = got + 1
    }
    return total
}






// ---- 1. Monte Carlo pi: embarrassingly-parallel float compute ------------------
// Each task runs an independent MINSTD stream (no shared RNG, no wrapping overflow —
// a*x stays well inside i64) and counts samples landing in the unit quarter-circle.

fn mc_hits(seed: int, samples: int) -> int {
    var x = seed
    var hits = 0
    var i = 0
    loop {
        if i == samples {
            break
        }
        x = (16807 * x) % 2147483647
        let fx = to_float(x) / 2147483647.0
        x = (16807 * x) % 2147483647
        let fy = to_float(x) / 2147483647.0
        if fx * fx + fy * fy < 1.0 {
            hits = hits + 1
        }
        i = i + 1
    }
    return hits
}






fn mc_task(id: int, samples: int, out: Channel<int>) -> int {
    send(out, mc_hits(id * 2 + 1, samples))
    return 0
}






fn bench_montecarlo(tasks: int, samples: int) -> int {
    let t0 = clock()
    let out: Channel<int> = channel(64)
    nursery {
        for i in 0..tasks {
            spawn mc_task(i, samples, out)
        }
    }
    let hits = collect(out, tasks)
    println("SECTION montecarlo {hits} {ms_since(t0)}")
    return 0
}






// ---- 2. Prime counting: independent integer compute ----------------------------

fn is_prime(n: int) -> int {
    if n < 2 {
        return 0
    }
    var d = 2
    loop {
        if d * d > n {
            break
        }
        if n % d == 0 {
            return 0
        }
        d = d + 1
    }
    return 1
}






fn count_primes(lo: int, hi: int) -> int {
    var c = 0
    var n = lo
    loop {
        if n == hi {
            break
        }
        c = c + is_prime(n)
        n = n + 1
    }
    return c
}






fn primes_task(lo: int, hi: int, out: Channel<int>) -> int {
    send(out, count_primes(lo, hi))
    return 0
}






fn bench_primes(tasks: int, limit: int) -> int {
    let t0 = clock()
    let span = limit / tasks
    let out: Channel<int> = channel(64)
    nursery {
        for i in 0..tasks {
            spawn primes_task(i * span, i * span + span, out)
        }
    }
    let total = collect(out, tasks)
    println("SECTION primes {total} {ms_since(t0)}")
    return 0
}






// ---- 3. Allocation churn: per-worker allocator under contention ----------------

struct Box {
    v: int
}






fn churn(seed: int, iters: int) -> int {
    var sum = 0
    var i = 0
    loop {
        if i == iters {
            break
        }
        let b = Box { v: i + seed }       // allocated + dropped same-thread each iter
        sum = (sum + b.v) % 1000003
        i = i + 1
    }
    return sum
}






fn churn_task(id: int, iters: int, out: Channel<int>) -> int {
    send(out, churn(id + 1, iters))
    return 0
}






fn bench_alloc(tasks: int, iters: int) -> int {
    let t0 = clock()
    let out: Channel<int> = channel(64)
    nursery {
        for i in 0..tasks {
            spawn churn_task(i, iters, out)
        }
    }
    let total = collect(out, tasks)
    println("SECTION alloc {total} {ms_since(t0)}")
    return 0
}






// ---- 4. String pipe: heap objects crossing tasks through a channel -------------
// Producers build fresh heap strings and hand each to a collector running on another
// thread, which frees them — the cross-thread reclamation path, at channel-throughput.
// This is the WORST CASE on purpose: tiny messages, trivial per-message work, one hot
// channel, one consumer. It measures pure channel-op overhead, so the parallel runtime
// LOSES badly here (the per-op mutex cost dominates — see OFI-020); it is the floor, not
// a typical result. Give each message realistic work and the same channel hits ~5×.

fn producer(id: int, count: int, out: Channel<string>) -> int {
    var i = 0
    loop {
        if i == count {
            break
        }
        send(out, "task-{id}-item-{i}")     // fresh heap string → freed by the collector
        i = i + 1
    }
    return 0
}






fn collector(out: Channel<string>, n: int, done: Channel<int>) -> int {
    var bytes = 0
    var got = 0
    loop {
        if got == n {
            break
        }
        match recv(out) {
            case Some(s) { bytes = bytes + s.len() }
            case None    { break }
        }
        got = got + 1
    }
    send(done, bytes)
    return 0
}






fn bench_pipe(producers: int, per: int) -> int {
    let t0 = clock()
    let out:  Channel<string> = channel(256)
    let done: Channel<int>    = channel(2)
    nursery {
        spawn collector(out, producers * per, done)
        for i in 0..producers {
            spawn producer(i, per, out)
        }
    }
    let bytes = collect(done, 1)
    println("SECTION pipe {bytes} {ms_since(t0)}")
    return 0
}






// ---- 5. Nested divide & conquer: nested nurseries / thread-per-fiber stress -----
// Sums work(i) over [lo,hi) by recursively splitting in two, going parallel for the
// top `depth` levels (each split spawns two sub-tasks in its own nursery) and serial
// below. Addition mod a prime is associative, so the answer is split-order-independent.

fn work(i: int) -> int {
    return (i * 2654435761) % 1000003
}






fn psum_serial(lo: int, hi: int) -> int {
    var s = 0
    var i = lo
    loop {
        if i == hi {
            break
        }
        s = (s + work(i)) % 1000003
        i = i + 1
    }
    return s
}






fn psum_task(lo: int, hi: int, depth: int, out: Channel<int>) -> int {
    send(out, psum(lo, hi, depth))
    return 0
}






fn psum(lo: int, hi: int, depth: int) -> int {
    if depth == 0 {
        return psum_serial(lo, hi)
    }
    let mid = (lo + hi) / 2
    let ch: Channel<int> = channel(2)
    nursery {
        spawn psum_task(lo, mid, depth - 1, ch)
        spawn psum_task(mid, hi, depth - 1, ch)
    }
    return (collect(ch, 2)) % 1000003
}






fn bench_nested(limit: int, depth: int) -> int {
    let t0 = clock()
    let total = psum(0, limit, depth)
    println("SECTION nested {total} {ms_since(t0)}")
    return 0
}






fn main() -> int {
    let tasks = 16
    bench_montecarlo(tasks, 2000000)
    bench_primes(tasks, 600000)
    bench_alloc(tasks, 2000000)
    bench_pipe(tasks, 20000)
    bench_nested(8000000, 4)
    return 0
}
