// temp_receiver.em — native differential test (OFI-054): a method call on a TEMPORARY receiver
// (a fresh value, not a named binding) — `mk(i).s()` and the chained `a.scaled(3).add(b)` where
// the receiver of `.add` is itself the temp from `.scaled(3)`. A value-struct temp has no heap, so
// it flows by value; a boxed temp receiver would be dropped after the call. The VM is the reference.
struct Pt {
    x: int
    y: int

    fn scaled(self, k: int) -> Pt {
        return Pt { x: self.x * k, y: self.y * k }
    }

    fn add(self, o: Pt) -> Pt {
        return Pt { x: self.x + o.x, y: self.y + o.y }
    }

    fn sum(self) -> int {
        return self.x + self.y
    }
}

fn mk(i: int) -> Pt {
    return Pt { x: i, y: i * 2 }
}

fn main() -> int {
    let a = Pt { x: 1, y: 2 }
    let b = Pt { x: 10, y: 20 }
    let chained = a.scaled(3).add(b)      // {3+10, 6+20} = {13, 26}
    var total = 0
    var i = 0
    loop {
        if i == 4 { break }
        total = total + mk(i).sum()       // mk(i).sum() = i + 2i = 3i; sum over 0..3 = 18
        i = i + 1
    }
    return chained.x + chained.y + total  // 13 + 26 + 18 = 57
}
