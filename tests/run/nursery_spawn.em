// nursery_spawn.em — structured concurrency (green threads). Tasks spawned in a
// nursery run to completion before the block exits; the join is structural.
fn task(n: int) -> int {
    println(n)
    return 0
}
fn main() -> int {
    nursery {
        spawn task(1)
        spawn task(2)
        spawn task(3)
    }
    println(0)        // prints only after all three tasks have finished
    return 0
}
