// io_file.em — file I/O round-trip: write a file, read it back, and process it.
// Self-contained (writes to a temp path), so it needs no external fixture and its
// output is deterministic. Exercises write_file / read_file plus string split.
fn main() -> int {
    let path = "/tmp/ember_io_regression.txt"
    write_file(path, "one\ntwo\nthree")
    let text = read_file(path)
    let lines = text.split("\n")
    var total = 0
    var i = 0
    loop {
        if i == lines.len() { break }
        total = total + lines[i].len()        // 3 + 3 + 5 = 11
        i = i + 1
    }
    let missing = read_file("/tmp/ember_no_such_file_zzz.txt")   // graceful: ""
    println("lines={lines.len()} chars={total} missing={missing.len()}")
    return lines.len() + total + missing.len()                   // 3 + 11 + 0 = 14
}
