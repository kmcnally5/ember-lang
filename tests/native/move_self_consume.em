// move_self_consume.em — a `move self` method CONSUMES its receiver (OFI-145 / R5p2). The receiver
// binding is marked moved (use-after-move is a compile error — see tests/run/error_move_self_after_move.em)
// and codegen nils its slot, so the caller's scope exit does NOT double-drop the value the method
// already released. Looped 1000× with a kept (refcounted) array field, so a double-free or leak shows
// up on the VM (the reclaim detector) and as a compiled binary — and the two backends must AGREE.
struct Bag {
    items: [int]

    fn sum_and_consume(move self) -> int {
        var t = 0
        var i = 0
        loop {
            if i == self.items.len() { break }
            t = t + self.items[i]
            i = i + 1
        }
        return t
    }
}

fn main() -> int {
    var total = 0
    var n = 0
    loop {
        if n == 1000 { break }
        let b = Bag { items: [n, n + 1, n + 2] }
        total = total + b.sum_and_consume()
        n = n + 1
    }
    return total % 7
}
