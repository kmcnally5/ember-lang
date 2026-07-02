// Native backend differential test for from_bytes(bytes: [u8]) -> string — the Ember-side binary-serializer
// primitive for the .emb bytecode container (docs/design/bytecode-container.md). The harness runs this on
// the VM and as a compiled binary and requires identical stdout. from_bytes builds a string whose RAW
// buffer is EXACTLY the [u8] array: no UTF-8 re-encoding, so it can hold a NUL and any 0x80–0xFF byte as a
// SINGLE byte — unlike from_char_code, which UTF-8-encodes and emits two bytes for a high code point.

fn byte_sum(s: string) -> int {
    let bs = s.bytes()
    var i = 0
    var sum = 0
    loop {
        if i >= bs.len() {
            break
        }
        sum = sum + int(bs[i])
        i = i + 1
    }
    return sum
}


fn main() -> int {
    // Arbitrary bytes: printable ASCII, a NUL, and two high bytes from_char_code cannot express in one
    // byte. 69 'E', 77 'M', 66 'B', 1, 0 (NUL), 200 (0xC8), 255 (0xFF).
    var raw: [u8] = []
    raw.append(69)
    raw.append(77)
    raw.append(66)
    raw.append(1)
    raw.append(0)
    raw.append(200)
    raw.append(255)

    let s = from_bytes(raw)
    println("len={s.len()}")                    // 7 (byte length, NUL included)
    println("sum={byte_sum(s)}")                // 69+77+66+1+0+200+255 = 668

    // .bytes() is the inverse: every byte round-trips exactly, including the NUL and the high bytes.
    let back = s.bytes()
    println("nbytes={back.len()}")              // 7
    println("b4={int(back[4])} b5={int(back[5])} b6={int(back[6])}")   // 0 200 255

    // A high byte is a SINGLE byte via from_bytes, but TWO via from_char_code (UTF-8) — the whole reason
    // the builtin exists.
    var hi: [u8] = []
    hi.append(200)
    println("from_bytes_hi_len={from_bytes(hi).len()}")           // 1
    println("from_char_code_hi_len={from_char_code(200).len()}")  // 2

    // Empty array -> empty string.
    var none: [u8] = []
    println("empty_len={from_bytes(none).len()}")                 // 0

    // End-to-end binary write path: from_bytes + write_file emits exact bytes; read_file + .bytes() reads
    // them back unchanged (the serializer's actual output path for the .emb container).
    write_file("/tmp/ember_from_bytes_diff.bin", s)
    let disk = read_file("/tmp/ember_from_bytes_diff.bin")
    println("disk_len={disk.len()} disk_sum={byte_sum(disk)}")    // 7 668
    return 0
}
