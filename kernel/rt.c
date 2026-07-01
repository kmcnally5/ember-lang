//
// rt.c — the freestanding runtime shim for the bare-metal spike (OFI-167 / kernel milestone 1).
//
// The heap-free subset of emberc's `--emit=c` output needs only: an output primitive, integer
// arithmetic, equality, truthiness, a panic, and a no-op object-sweep. All are implemented here with
// NO libc and NO heap. `uart_putc` is the one hardware primitive — it writes a byte to the QEMU
// `virt` board's PL011 UART data register (0x0900_0000), which under `-nographic` is wired to the
// terminal. Everything else is pure integer work on the tagged Value.
//
#include "ember_rt.h"

#define PL011_DR ((volatile uint32_t *)0x09000000u)   // PL011 UART data register (QEMU `virt`)


// The single MMIO primitive Ember calls via `extern "c"`: emit one byte to the UART.
void uart_putc(int32_t c) {
    *PL011_DR = (uint32_t)c;
}


int    em_argc = 0;      // set by the emitted main from argc/argv; unused on bare metal
char **em_argv = 0;


// Integer add. The heap-free subset only adds i64 loop counters, so `kind` (the declared width) is
// unused here; overflow traps, matching the hosted runtime's no-UB rule (CLAUDE.md).
Value em_add(EmberRt *ctx, Value a, Value b, int kind) {
    (void)ctx;
    (void)kind;
    int64_t r;
    if (__builtin_add_overflow(AS_INT(a), AS_INT(b), &r)) {
        em_panic("integer overflow");
    }
    return INT_VAL(r);
}


// Integer equality -> a 0/1 bool Value.
Value em_eq_op(EmberRt *ctx, Value a, Value b) {
    (void)ctx;
    return INT_VAL(AS_INT(a) == AS_INT(b) ? 1 : 0);
}


// Truthiness of a bool/int Value.
int em_truthy(Value v) {
    return AS_INT(v) != 0;
}


// A kernel panic is terminal — there is no OS to unwind to. Print the message to the UART, then hang.
void em_panic(const char *msg) {
    for (const char *p = msg; p != NULL && *p != '\0'; p++) {
        uart_putc((int32_t)(unsigned char)*p);
    }
    uart_putc((int32_t)'\n');
    for (;;) {
    }
}


// No heap on bare metal -> nothing to reclaim.
void rt_free_objects(EmberRt *ctx) {
    (void)ctx;
}


// The emitted `main` echoes its integer result with printf; the real program output is the uart_putc
// stream, so a no-op printf keeps the heap-free subset self-contained. (A proper freestanding printf
// routed to the UART is a later increment.) With `-nostdlib` this definition satisfies the reference.
int printf(const char *fmt, ...) {
    (void)fmt;
    return 0;
}


// The compiler backend may lower struct copies / zeroing to these; a freestanding target must supply
// them itself. Minimal byte-wise implementations (correctness over speed for the spike).
void *memcpy(void *dst, const void *src, size_t n) {
    unsigned char       *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    for (size_t i = 0; i < n; i++) {
        d[i] = s[i];
    }
    return dst;
}


void *memset(void *dst, int c, size_t n) {
    unsigned char *d = (unsigned char *)dst;
    for (size_t i = 0; i < n; i++) {
        d[i] = (unsigned char)c;
    }
    return dst;
}
