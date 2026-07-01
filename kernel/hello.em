// kernel/hello.em — Ember's first bare-metal spike (kernel-freestanding milestone 1).
//
// A heap-free `main` that boots on QEMU `aarch64 virt` and prints to the PL011 UART, with
// NO libc and NO heap. The only output path is `uart_putc`, an `extern "c"` function whose C
// body (in the freestanding shim `rt.c`) writes bytes to the UART data register at 0x0900_0000.
//
// Everything here stays in the heap-free subset: scalar `i32`/`int`, a counted loop, and
// `extern "c"` scalar calls. No strings, arrays, or boxed values — those need the allocator,
// which bare metal does not have yet. The message is emitted byte-by-byte on purpose.
extern "c" {
    fn uart_putc(c: i32)
}


// Emit one ASCII byte to the UART. A thin wrapper so `main` reads as a sequence of characters.
fn putc(c: i32) {
    uart_putc(c)
}


fn main() -> int {
    // "Hello from Ember!\n" — hardcoded bytes (no string type yet, to stay 100% heap-free).
    putc(72)   // H
    putc(101)  // e
    putc(108)  // l
    putc(108)  // l
    putc(111)  // o
    putc(32)   // (space)
    putc(102)  // f
    putc(114)  // r
    putc(111)  // o
    putc(109)  // m
    putc(32)   // (space)
    putc(69)   // E
    putc(109)  // m
    putc(98)   // b
    putc(101)  // e
    putc(114)  // r
    putc(33)   // !
    putc(10)   // \n

    // A counted loop — exercises the integer runtime path (em_add / em_eq_op / em_truthy) on
    // bare metal, proving arithmetic works with no OS underneath. Prints three dots.
    var i = 0
    loop {
        if i == 3 { break }
        putc(46)   // .
        i = i + 1
    }
    putc(10)   // \n

    return 0
}
