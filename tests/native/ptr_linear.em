// OFI-049 positive (leak half): a `Ptr` is now a LINEAR FFI handle — move-only (affine, the
// double-close half) AND must-consume (closed on every path, the leak half). This exercises the
// must-consume control-flow the checker proves with its AND-merge: a CLOSE-ON-BREAK read loop (an
// outer handle consumed on the only loop exit) and a CONDITIONAL close balanced across an if/else.
// Both close on every path, so they compile, run, and agree VM == native. Self-contained (temp
// files), deterministic output.
extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fwrite(buf: [u8], n: i64, f: Ptr) -> i64
    fn fclose(move f: Ptr) -> i64
}

fn drain(path: string, n: int) -> i64 {
    var f = fopen(path, "w")
    var bytes: [u8] = []
    bytes.append(88u8)
    var i = 0
    var w: i64 = 0
    loop {
        if i == n {
            let _c = fclose(f)          // close-on-break: f consumed on the only loop exit
            break
        }
        w = w + fwrite(bytes, 1, f)     // borrow f each iteration
        i = i + 1
    }
    return w
}

fn pick(path: string, hot: bool) -> i64 {
    var f = fopen(path, "w")
    var bytes: [u8] = []
    bytes.append(89u8)
    var r: i64 = 0
    if hot {
        r = fwrite(bytes, 1, f)
        let _a = fclose(f)              // closed on the then-branch …
    } else {
        let _b = fclose(f)              // … and on the else-branch — balanced (AND-merge)
    }
    return r
}

fn main() -> int {
    let a = drain("/tmp/ember_ptr_linear_a.bin", 3)
    let b = pick("/tmp/ember_ptr_linear_b.bin", true)
    let c = pick("/tmp/ember_ptr_linear_c.bin", false)
    println("drain {a} pick {b} {c}")
    return 0
}
