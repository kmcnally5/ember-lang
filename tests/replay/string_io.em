// string_io.em — verification loop (§5j) brick 3, string sources: `read_file` (and `read_line`)
// are nondeterministic external reads, so record-replay captures the bytes they return and feeds
// them back on replay (no real I/O the second time). The two runs — including the file contents
// woven into the program's output — must be byte-for-byte identical.
fn main() -> int {
    let a = read_file("tests/replay/fixture.txt")
    let b = read_file("tests/replay/fixture.txt")
    println("first read:\n{a}")
    println("second read:\n{b}")
    return 0
}
