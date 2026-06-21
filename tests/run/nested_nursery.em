// nested_nursery.em — a nursery opened INSIDE a task that is itself running in a
// nursery. Divide-and-conquer: sum 0..64 by recursively splitting in two, each split
// spawning its two halves in its own nursery, down to a depth of 3. Addition is
// associative, so the answer (2016) is independent of how the work is split — and it
// must be identical whether tasks run cooperatively on one thread (serial) or on real
// OS threads (EMBER_PARALLEL). Regression guard for the nested-nursery group-stack bug
// (a closing nursery must not pop its slot until its tasks — which may open their own
// nurseries — have finished).
enum Option<T> {
    Some(value: T)
    None
}

fn psum_serial(lo: int, hi: int) -> int {
    var s = 0
    var i = lo
    loop {
        if i == hi {
            break
        }
        s = s + i
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
    var total = 0
    var k = 0
    loop {
        if k == 2 {
            break
        }
        match recv(ch) {
            case Some(v) { total = total + v }
            case None    { break }
        }
        k = k + 1
    }
    return total
}

fn main() -> int {
    println(psum(0, 64, 3))      // 0+1+...+63 = 2016
    return 0
}
