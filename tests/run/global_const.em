// global_const.em — top-level `let` constants (OFI-023): named, immutable, compile-
// time values that resolve in any function of the module and are substituted at each
// use site. Here they drive arithmetic and a string.
let WIDTH  = 800
let HEIGHT = 600
let TITLE  = "ember"

fn area() -> int {
    return WIDTH * HEIGHT
}

fn main() -> int {
    println(TITLE)
    return area() - 479600       // 800*600 - 479600 = 400
}
