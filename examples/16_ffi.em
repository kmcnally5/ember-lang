// 16_ffi.em — binding real C through the pointer/buffer FFI (MANIFESTO §5h).
//
// An `extern "c"` block is the trust boundary: each signature names a C function and the types
// Ember marshals across. Beyond scalars and structs-by-value, Ember passes three pointer flavours
// — all BORROWED for the duration of the call, so Ember keeps ownership and frees nothing C owns:
//
//   string        ->  const char*   (the string's bytes, NUL-terminated)
//   [u8] / mut [u8] -> a buffer      (the array's contiguous native storage; `mut` = C may write)
//   Ptr           ->  an opaque handle (FILE*, void*, …) that round-trips but is never dereferenced
//
// Here we bind a slice of libc and use it to write a file and read it straight back.
extern "c" {
    fn strlen(s: string) -> i64
    fn fopen(path: string, mode: string) -> Ptr
    fn fwrite(buf: [u8], n: i64, f: Ptr) -> i64
    fn fread(mut buf: [u8], n: i64, f: Ptr) -> i64
    fn fclose(move f: Ptr) -> i64
}


// Fill a buffer of `n` zero bytes so a foreign reader has somewhere to write.
fn zeroed(n: int) -> [u8] {
    var buf: [u8] = []
    var i = 0
    loop {
        if i == n { break }
        buf.append(0u8)
        i = i + 1
    }
    return buf
}


fn main() -> int {
    let path = "/tmp/ember_ffi_demo.bin"

    // A small payload: the bytes of "EMBER" (a [u8] buffer, borrowed by fwrite).
    var msg: [u8] = []
    msg.append(69u8)   // E
    msg.append(77u8)   // M
    msg.append(66u8)   // B
    msg.append(69u8)   // E
    msg.append(82u8)   // R

    // fopen returns an opaque Ptr handle; fwrite borrows the buffer; fclose releases the handle.
    let wf = fopen(path, "w")
    let wrote = fwrite(msg, msg.len(), wf)
    let _cw = fclose(wf)
    println("wrote {wrote} bytes to {path}")

    // Read it back into a fresh, mutable buffer that the C side writes in place.
    var back: [u8] = zeroed(msg.len())
    let rf = fopen(path, "r")
    let got = fread(back, msg.len(), rf)
    let _cr = fclose(rf)

    // Reconstruct the text byte by byte (chr-by-chr) to prove the round-trip.
    var i = 0
    var text = ""
    loop {
        if i == got { break }
        text = text + byte_to_letter(back[i])
        i = i + 1
    }
    println("read back {got} bytes: {text}")

    // 'p' leaf: strlen over a borrowed string literal (the temp is released after the call).
    println("strlen(\"{text}\") = {strlen(text)}")
    return got
}


// Map an uppercase-letter byte back to its single-character string (A=65..Z=90).
fn byte_to_letter(b: u8) -> string {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    let idx = i64(b) - 65
    if idx < 0 { return "?" }
    if idx >= alphabet.len() { return "?" }
    let chars = alphabet.chars()
    return chars[idx]
}
