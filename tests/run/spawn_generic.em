// spawn_generic.em — regression for REVIEW_FINDINGS M13: spawning a BOUNDED GENERIC function.
// `spawn` shares the direct-call calling convention, so it must monomorphize the target and push
// the bound witnesses as hidden leading args. Before the fix it spawned the generic base slot with
// no witnesses and the fiber crashed (SIGSEGV). Here a bounded `<K: Hash + Eq>` task runs in a
// nursery and reports through a channel, exercising witness dispatch (a.eq / a.hash) on the fiber.
fn tally<K: Hash + Eq>(ch: Channel<int>, a: K, b: K) {
    var n = 0
    if a.eq(b) { n = 1 }            // witness-dispatched eq
    send(ch, n)
}


fn main() -> int {
    let ch: Channel<int> = channel(2)
    nursery {
        spawn tally(ch, 5, 5)       // equal   -> 1
        spawn tally(ch, 7, 9)       // unequal -> 0
    }
    var total = 0
    var got = 0
    loop {
        if got == 2 { break }
        match recv(ch) {
            case Some(x) { total = total + x  got = got + 1 }
            case None    { break }
        }
    }
    return total                    // 1 + 0 = 1
}
