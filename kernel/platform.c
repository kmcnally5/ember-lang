//
// platform.c — the freestanding platform layer for the QEMU `virt` bare-metal target (kernel
// milestone 2; see docs/design/kernel-freestanding.md). Implements the libc subset declared in
// include/em_platform.h that the REAL Ember runtime (src/runtime.c, compiled -DEMBER_FREESTANDING)
// is written against: a bump allocator over a fixed .bss arena, byte-wise mem/str, a minimal printf
// family routed to the PL011 UART, and a panic-on-termination. No OS, no libc, no heap manager.
//
#include "em_platform.h"

#define PL011_DR ((volatile uint32_t *)0x09000000u)   // PL011 UART data register (QEMU `virt`)


// The one hardware primitive: emit a byte to the UART. Ember reaches it as a direct extern (OFI-167),
// and the platform's own output (fprintf/fwrite/panic messages) funnels through it too.
void uart_putc(int32_t c) {
    *PL011_DR = (uint32_t)c;
}


static void uart_puts(const char *s) {
    for (; s != NULL && *s != '\0'; s++) {
        uart_putc((int32_t)(unsigned char)*s);
    }
}


// ---- bump allocator over a fixed .bss arena --------------------------------------------------------
// free() is a no-op — objects leak within the arena and it resets wholesale (a batch/kernel model,
// not a general heap). Each block is 16-byte-prefixed with its payload length so realloc knows how
// much to copy; the 16-byte header also keeps the payload 16-aligned (Value/Obj alignment).
#define EM_ARENA_SIZE (16u * 1024u * 1024u)   // 16 MiB

static uint8_t em_arena[EM_ARENA_SIZE] __attribute__((aligned(16)));
static size_t  em_arena_off = 0;


// ---- exception handler (kernel milestone 3) --------------------------------------------------------
// Called from the vector-table stub (kernel/vectors.S) on any CPU exception, with the exception index
// and the syndrome registers. There is nothing to recover to on a bare-metal fault, so it prints a
// diagnostic panic and halts — turning what used to be a silent spin into a readable report. The EC
// (exception class) is the most useful field: 0x25 = data abort, 0x07 = SIMD/FP trapped, 0x3c = BRK, …
void em_exception(uint64_t kind, uint64_t esr, uint64_t elr, uint64_t far) {
    static const char *const KINDS[16] = {
        "EL0 sync", "EL0 irq", "EL0 fiq", "EL0 serror",
        "sync", "irq", "fiq", "serror",
        "lower64 sync", "lower64 irq", "lower64 fiq", "lower64 serror",
        "lower32 sync", "lower32 irq", "lower32 fiq", "lower32 serror",
    };
    char buf[160];
    uart_puts("\n*** EMBER KERNEL PANIC: CPU exception ***\n");
    snprintf(buf, sizeof buf,
             "  vector=%llu (%s)  EC=0x%llx  ESR=0x%llx  ELR=0x%llx  FAR=0x%llx\n",
             (unsigned long long)kind, KINDS[kind & 15],
             (unsigned long long)((esr >> 26) & 0x3f),
             (unsigned long long)esr, (unsigned long long)elr, (unsigned long long)far);
    uart_puts(buf);
    uart_puts("  halted.\n");
    for (;;) {
    }
}


// A deliberate synchronous CPU exception (a BRK), for the fault-vector regression (kernel/faultdemo.em
// calls it as a direct extern). Proves the vector table catches a fault and reports it, rather than
// the process hanging silently.
void cpu_break(void) {
    __asm__ volatile("brk #0");
}


// ---- MMU: a minimal identity map so unaligned accesses work ----------------------------------------
// With the MMU OFF (reset state), every data access is treated as Device memory, which faults on any
// UNALIGNED access — and the Ember runtime is full of them (packed struct fields, 16-byte Value copies
// via ldp/stp). So we install a flat identity map that marks RAM as Normal cacheable (unaligned OK,
// and fast) and the low 1 GiB as Device (the UART lives there), then enable the MMU. A single level-1
// table with 1 GiB block descriptors is all a first kernel needs. Called from boot.S before main.
static uint64_t l1_table[512] __attribute__((aligned(4096)));

void mmu_init(void) {
    for (int i = 0; i < 512; i++) {
        l1_table[i] = 0;                              // unmapped (a stray access past mapped RAM faults)
    }
    // Block descriptor bits: [1:0]=01 block, [4:2]=AttrIndx, [7:6]=AP(00 EL1 RW), [9:8]=SH,
    // [10]=AF(1), [54]=XN (execute-never). Device -> AttrIndx0/SH=0/XN (no code at MMIO);
    // Normal -> AttrIndx1/SH=11 (inner shareable), executable (code runs from RAM).
    l1_table[0] = 0x0ull | (0ull << 2) | (0ull << 8) | (1ull << 10) | (1ull << 54) | 0x1ull;  // 0x0000_0000 Device (UART), XN
    // RAM at 0x4000_0000: map 8 GiB of 1 GiB blocks (identity) as Normal cacheable, so a large `-m`
    // still has its whole arena/stack mapped (QEMU virt default is 128 MiB, within the first block).
    for (uint64_t g = 1; g <= 8; g++) {
        l1_table[g] = (g << 30) | (1ull << 2) | (3ull << 8) | (1ull << 10) | 0x1ull;
    }

    uint64_t mair = (0x00ull << 0) | (0xFFull << 8);  // attr0 = Device-nGnRnE, attr1 = Normal WB
    // TCR_EL1: T0SZ=25 (39-bit VA -> L1 is the top level, 1 GiB blocks), 4 KiB granule, WB cacheable
    // page-table walks, inner shareable, 40-bit physical addresses.
    uint64_t tcr = 25ull | (1ull << 8) | (1ull << 10) | (3ull << 12) | (0ull << 14) | (2ull << 32);

    __asm__ volatile("msr mair_el1, %0"  :: "r"(mair));
    __asm__ volatile("msr tcr_el1, %0"   :: "r"(tcr));
    __asm__ volatile("msr ttbr0_el1, %0" :: "r"((uint64_t)(uintptr_t)l1_table));
    __asm__ volatile("dsb ish; tlbi vmalle1; dsb ish; isb");

    uint64_t sctlr;
    __asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
    sctlr |= (1ull << 0) | (1ull << 2) | (1ull << 12);   // M (MMU), C (data cache), I (instr cache)
    __asm__ volatile("msr sctlr_el1, %0" :: "r"(sctlr));
    __asm__ volatile("isb");
}


// A platform OOM is terminal and layered BELOW the runtime, so it halts directly rather than calling
// up into em_panic (which would depend back on this file's fprintf/exit).
static void bump_oom(void) {
    uart_puts("*** freestanding bump arena exhausted ***\n");
    for (;;) {
    }
}


static void *bump(size_t n) {
    size_t aligned = (n + 15u) & ~(size_t)15u;
    if (em_arena_off + aligned > EM_ARENA_SIZE) {
        bump_oom();
    }
    void *p = &em_arena[em_arena_off];
    em_arena_off += aligned;
    return p;
}


void *malloc(size_t n) {
    uint8_t *block = (uint8_t *)bump(16u + n);
    *(size_t *)block = n;             // stash the payload length for realloc
    return block + 16u;
}


void *calloc(size_t count, size_t size) {
    size_t n = count * size;
    if (size != 0 && n / size != count) {   // multiply overflow -> can't satisfy the request
        bump_oom();
    }
    void *p = malloc(n);
    memset(p, 0, n);
    return p;
}


void *realloc(void *p, size_t n) {
    if (p == NULL) {
        return malloc(n);
    }
    size_t old = *(size_t *)((uint8_t *)p - 16u);
    void  *np  = malloc(n);
    memcpy(np, p, old < n ? old : n);
    return np;                        // the old block leaks (bump arena)
}


void free(void *p) {
    (void)p;                          // no per-object free in a bump arena
}


// ---- mem / str -------------------------------------------------------------------------------------
void *memcpy(void *dst, const void *src, size_t n) {
    unsigned char       *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    for (size_t i = 0; i < n; i++) {
        d[i] = s[i];
    }
    return dst;
}


void *memmove(void *dst, const void *src, size_t n) {
    unsigned char       *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s) {
        for (size_t i = 0; i < n; i++) {
            d[i] = s[i];
        }
    } else {
        for (size_t i = n; i > 0; i--) {
            d[i - 1] = s[i - 1];
        }
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


int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = (const unsigned char *)a;
    const unsigned char *y = (const unsigned char *)b;
    for (size_t i = 0; i < n; i++) {
        if (x[i] != y[i]) {
            return (int)x[i] - (int)y[i];
        }
    }
    return 0;
}


size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n] != '\0') {
        n++;
    }
    return n;
}


// ---- minimal printf family, routed to the UART -----------------------------------------------------
// Covers the specifiers src/runtime.c uses: %s %c %d/%i %u %l/%ll widths %x %p %g %%. Enough for the
// runtime's fault/number-rendering paths; not a general printf.
static char *emit_uint(char *p, char *end, uint64_t v, unsigned base, int upper) {
    char tmp[24];
    int  i = 0;
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    if (v == 0) {
        tmp[i++] = '0';
    }
    while (v > 0) {
        tmp[i++] = digits[v % base];
        v /= base;
    }
    while (i > 0 && p < end) {
        *p++ = tmp[--i];
    }
    return p;
}


static char *emit_int(char *p, char *end, int64_t v) {
    if (v < 0 && p < end) {
        *p++ = '-';
        return emit_uint(p, end, (uint64_t)(-(v + 1)) + 1u, 10, 0);
    }
    return emit_uint(p, end, (uint64_t)v, 10, 0);
}


// A crude but honest %g: sign, integer part, then up to 6 fractional digits. Good enough for a fault
// message on bare metal (float-heavy formatting is not on the kernel path).
static char *emit_float(char *p, char *end, double v) {
    if (v < 0) {
        if (p < end) { *p++ = '-'; }
        v = -v;
    }
    if (!(v < 18446744073709551616.0)) {   // >= 2^64 (or NaN): a (uint64_t) cast would be UB
        for (const char *s = "inf"; *s != '\0' && p < end; s++) { *p++ = *s; }
        return p;
    }
    uint64_t ip = (uint64_t)v;
    p = emit_uint(p, end, ip, 10, 0);
    double frac = v - (double)ip;
    if (p < end) { *p++ = '.'; }
    for (int i = 0; i < 6 && p < end; i++) {
        frac *= 10.0;
        int d = (int)frac;
        *p++ = (char)('0' + d);
        frac -= (double)d;
    }
    return p;
}


int vsnprintf(char *buf, size_t n, const char *fmt, va_list ap) {
    char *p   = buf;
    char *end = (n > 0) ? buf + n - 1 : buf;   // reserve the NUL
    for (; *fmt != '\0'; fmt++) {
        if (*fmt != '%') {
            if (p < end) { *p++ = *fmt; }
            continue;
        }
        fmt++;
        int longs = 0;
        while (*fmt == 'l') { longs++; fmt++; }
        switch (*fmt) {
            case 's': {
                const char *s = va_arg(ap, const char *);
                if (s == NULL) { s = "(null)"; }
                while (*s != '\0' && p < end) { *p++ = *s++; }
                break;
            }
            case 'c': {
                int c = va_arg(ap, int);
                if (p < end) { *p++ = (char)c; }
                break;
            }
            case 'd':
            case 'i': {
                int64_t v = (longs >= 2) ? va_arg(ap, long long)
                          : (longs == 1) ? va_arg(ap, long)
                          :                va_arg(ap, int);
                p = emit_int(p, end, v);
                break;
            }
            case 'u': {
                uint64_t v = (longs >= 2) ? va_arg(ap, unsigned long long)
                           : (longs == 1) ? va_arg(ap, unsigned long)
                           :                va_arg(ap, unsigned int);
                p = emit_uint(p, end, v, 10, 0);
                break;
            }
            case 'x':
            case 'X': {
                uint64_t v = (longs >= 2) ? va_arg(ap, unsigned long long)
                           : (longs == 1) ? va_arg(ap, unsigned long)
                           :                va_arg(ap, unsigned int);
                p = emit_uint(p, end, v, 16, *fmt == 'X');
                break;
            }
            case 'p': {
                void *v = va_arg(ap, void *);
                if (p < end) { *p++ = '0'; }
                if (p < end) { *p++ = 'x'; }
                p = emit_uint(p, end, (uint64_t)(uintptr_t)v, 16, 0);
                break;
            }
            case 'g':
            case 'f': {
                double v = va_arg(ap, double);
                p = emit_float(p, end, v);
                break;
            }
            case '%':
                if (p < end) { *p++ = '%'; }
                break;
            default:
                if (p < end) { *p++ = '%'; }
                if (p < end) { *p++ = *fmt; }
                break;
        }
    }
    if (n > 0) { *p = '\0'; }
    return (int)(p - buf);
}


int snprintf(char *buf, size_t n, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = vsnprintf(buf, n, fmt, ap);
    va_end(ap);
    return r;
}


// The runtime writes diagnostics through stderr/stdout; on bare metal both are the one UART console.
// The stream pointers are non-NULL sentinels the runtime only passes back to us.
struct EmFile { int _unused; };
static struct EmFile em_console_file;
FILE *stderr = &em_console_file;
FILE *stdout = &em_console_file;


int fprintf(FILE *stream, const char *fmt, ...) {
    (void)stream;
    char    buf[256];
    va_list ap;
    va_start(ap, fmt);
    int r = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    uart_puts(buf);
    return r;
}


size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream) {
    (void)stream;
    const unsigned char *b = (const unsigned char *)ptr;
    size_t total = size * nmemb;
    for (size_t i = 0; i < total; i++) {
        uart_putc((int32_t)b[i]);
    }
    return nmemb;
}


int fputc(int c, FILE *stream) {
    (void)stream;
    uart_putc((int32_t)(unsigned char)c);
    return c;
}


// ---- termination: no OS to return to -------------------------------------------------------------
void exit(int code) {
    (void)code;    // a bare-metal exit() (a trap or the exit() builtin) is terminal — halt.
    for (;;) {
    }
}


void abort(void) {
    uart_puts("*** abort ***\n");
    for (;;) {
    }
}
