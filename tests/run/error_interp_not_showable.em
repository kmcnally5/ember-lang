// OFI-139: interpolating a value whose type does NOT provide `fn show(self) -> string`
// is a compile error that names the Show contract and the field/method workaround,
// instead of the old bare "accepts a number, a string, or a bool".

struct Bare {
    n: int
}


fn main() {
    let b = Bare { n: 5 }
    println("value = {b}")
}
