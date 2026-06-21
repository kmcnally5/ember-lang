// loop.em — locks the loop bytecode: OP_LOOP back-edge and the break forward jump.
fn main() -> int {
    var i = 0
    loop {
        if i >= 2 { break }
        i = i + 1
    }
    return i
}
