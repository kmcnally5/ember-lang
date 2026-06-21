// print_loop.em — print runs for effect inside a loop (expression statements).
fn main() -> int {
    var i = 0
    loop {
        if i >= 3 { break }
        println(i)
        i = i + 1
    }
    return 0
}
