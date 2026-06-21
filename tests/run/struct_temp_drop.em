// struct_temp_drop.em — a fresh owned struct temporary used transiently (then discarded)
// must be reclaimed, not leaked (OFI-027). This exercises every transient shape the fix
// covers and checks a deterministic result — a double-free would crash or corrupt it, a
// borrowed local reused after a call proves the call didn't free the caller's value.
// (The leak itself is verified out-of-suite by RSS staying flat over millions of iters.)
struct P {
    x: int
    y: int


    fn s(self) -> int {
        return self.x + self.y
    }


    fn add(self, o: P) -> int {
        return self.x + o.y
    }
}


fn mk(i: int) -> P {
    return P { x: i, y: i * 2 }
}


fn take(p: P) -> int {
    return p.x + p.y
}


fn two(a: P, b: P) -> int {
    return a.x + b.y
}


fn eat(move p: P) -> int {
    return p.x
}


fn main() -> int {
    var t = 0
    var i = 0
    loop {
        if i >= 50 {
            break
        }
        let local = mk(i)                       // bound; reused after borrows below
        t = t + take(local) + local.x + local.s()   // local must survive (no double-free)
        t = t + take(mk(i))                     // borrow-arg temp
        t = t + mk(i).s()                       // method-receiver temp
        t = t + mk(i).x                         // field-object temp
        mk(i)                                   // discarded temp
        t = t + two(mk(i), mk(i))               // two temp args
        t = t + local.add(mk(i))                // method-arg temp
        t = t + eat(mk(i))                      // move param consumes the temp
        i = i + 1
    }
    return t % 100003
}
