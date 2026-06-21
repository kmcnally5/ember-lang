// tests/native/struct_array_field.em — OFI-061: assigning a field THROUGH an array index
// (`arr[i].field = v`) on an inline struct array. Covers a scalar field, a heap (string) field
// — whose old value must be released with no leak/double-free — and a loop of read-modify writes.
// Runs on BOTH the bytecode VM and the compiled binary; the harness asserts their stdout matches
// (the drift guard that keeps the AST->C writeback in lockstep with the VM's gen_nested_store).

struct Cell {
    tag: string
    n: int
}


// A struct whose FIELD is a struct array, mutated through an index INSIDE a method. This is the
// case that exposed the native temp-name collision (the writeback's hoist temp `a0` shadowed the
// `self` parameter `a0`): the VM was fine, the binary segfaulted. Keep it covered.
struct Grid {
    cells: [Cell]

    fn bump(mut self, i: int, by: int) {
        self.cells[i].n = self.cells[i].n + by
    }

    fn rename(mut self, i: int, name: string) {
        self.cells[i].tag = name
    }

    fn show(self) {
        var i = 0
        loop {
            if i == self.cells.len() {
                break
            }
            print("{self.cells[i].tag}={self.cells[i].n} ")
            i = i + 1
        }
    }
}

fn main() -> int {
    var cs: [Cell] = [
        Cell { tag: "a", n: 1 },
        Cell { tag: "b", n: 2 },
        Cell { tag: "c", n: 3 }
    ]
    cs[0].n = 10                 // scalar field through an index
    cs[2].n = 30
    cs[1].tag = "B!"             // heap field — the old "b" must be freed exactly once
    var i = 0
    loop {                       // read-modify-write in a loop
        if i == cs.len() {
            break
        }
        cs[i].n = cs[i].n + 100
        i = i + 1
    }
    i = 0
    loop {
        if i == cs.len() {
            break
        }
        print("{cs[i].tag}={cs[i].n}")
        i = i + 1
    }

    // The in-method field-array writeback (the native segfault case).
    var g = Grid { cells: [Cell { tag: "x", n: 1 }, Cell { tag: "y", n: 2 }] }
    g.bump(0, 100)
    g.rename(1, "Y!")
    g.bump(1, 5)
    print("|")
    g.show()
    return 0
}
