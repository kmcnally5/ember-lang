// boot.S — minimal aarch64 entry for the QEMU `virt` board (OFI-167 / kernel milestone 1).
//
// QEMU's `-kernel` loads this image at 0x4008_0000 and enters at `_start` on the primary CPU with
// the MMU off. We park any secondary CPUs, point sp at a stack carved from .bss, zero argc/argv, and
// branch to the C `main` the emitted Ember program provides. If `main` ever returns there is no OS
// to return to, so we hang.

.section .text.boot, "ax"
.global _start
_start:
    // Only the primary CPU (affinity 0) boots; secondaries wait forever.
    mrs     x1, mpidr_el1
    and     x1, x1, #0xff
    cbnz    x1, hang

    // Enable FP/SIMD access at EL1 (CPACR_EL1.FPEN = 0b11). FP/SIMD traps at reset, but clang copies
    // the runtime's 16-byte `Value` (its union holds a double) with 128-bit SIMD loads/stores — so
    // without this ANY non-trivial Ember code takes an "SIMD trapped" exception. Mandatory for a
    // bare-metal Ember target (kernel milestone 1 / OFI-167).
    mov     x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb

    ldr     x0, =stack_top          // set up the stack (grows down from stack_top)
    mov     sp, x0

    // Install the exception vector table (kernel milestone 3) as soon as we have a stack, so a fault
    // during the rest of setup is a printed panic, not a silent spin. VBAR_EL1 needs 2 KiB alignment
    // (vector_table provides it).
    ldr     x0, =vector_table
    msr     vbar_el1, x0
    isb

    // Enable the MMU with a flat identity map (kernel milestone 2). With the MMU off, every data
    // access is Device memory and faults on unaligned access — which the Ember runtime does
    // constantly. mmu_init (platform.c) maps RAM as Normal cacheable, then turns the MMU on.
    bl      mmu_init

    mov     x0, #0                  // argc = 0
    mov     x1, #0                  // argv = NULL
    bl      main

    // main returned — on bare metal there is no OS to go back to. Request a clean shutdown via ARM
    // semihosting SYS_EXIT (QEMU `-semihosting`), forwarding main's return value (w0) as the exit
    // code: the freestanding entry returns Ember main's int result, so the host-visible exit code
    // is COMPUTED BY EMBER on bare metal — a differential hook the smoke test asserts on. x1 points
    // at a writable {reason, exit_code} block. If semihosting is off the hlt is ignored and we fall
    // through to the hang loop.
    ldr     x1, =semi_exit_block
    sxtw    x0, w0                  // main's int return, widened
    str     x0, [x1, #8]            // block.exit_code = Ember main's result
    mov     x0, #0x18               // SYS_EXIT
    hlt     #0xf000

hang:
    wfe
    b       hang

.section .data
.align 3
semi_exit_block:
    .quad 0x20026                   // ADP_Stopped_ApplicationExit
    .quad 0                         // exit code, patched from main's return above

.section .bss, "aw", @nobits
.align 16
stack_bottom:
    .skip 0x10000                   // 64 KiB boot stack
stack_top:
