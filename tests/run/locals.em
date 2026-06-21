// locals.em — let/var bindings, reading a local, and assigning to a var.
// a=5; b=10; b=b+a (=15); return b*2 = 30.
fn main() -> int {
    let a = 5
    var b = 10
    b = b + a
    return b * 2
}
