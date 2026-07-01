// vectors.S — the aarch64 EL1 exception vector table (kernel milestone 3;
// docs/design/kernel-freestanding.md).
//
// Without a vector table, any CPU exception (a data abort, an undefined instruction, …) branches to
// VBAR's reset value and — with nothing there — spins forever: a silent hang, which is how the M1
// FP/SIMD trap and the M2 alignment fault first presented. This table catches all 16 exception
// entries and routes them to a common stub that reads the syndrome registers (ESR/ELR/FAR) and calls
// the C handler em_exception (kernel/platform.c), which prints a diagnostic panic and halts — so a
// fault is READABLE, not a mystery.
//
// The table must be 2 KiB-aligned (VBAR_EL1 requires bits[10:0]==0); each of the 16 entries occupies
// 0x80 bytes. boot.S sets VBAR_EL1 = vector_table once the stack is up.

.macro VECTOR kind
.align 7                         // each entry is 0x80 bytes
    mov     x0, #\kind           // the vector index (0..15), for the panic message
    b       exc_common
.endm

.section .text
.align 11                        // 2 KiB alignment for VBAR_EL1
.global vector_table
vector_table:
    VECTOR 0        // Current EL, SP0     : Synchronous
    VECTOR 1        //                     : IRQ
    VECTOR 2        //                     : FIQ
    VECTOR 3        //                     : SError
    VECTOR 4        // Current EL, SPx      : Synchronous  <- EL1h faults land here
    VECTOR 5        //                     : IRQ
    VECTOR 6        //                     : FIQ
    VECTOR 7        //                     : SError
    VECTOR 8        // Lower EL, AArch64    : Synchronous
    VECTOR 9        //                     : IRQ
    VECTOR 10       //                     : FIQ
    VECTOR 11       //                     : SError
    VECTOR 12       // Lower EL, AArch32    : Synchronous
    VECTOR 13       //                     : IRQ
    VECTOR 14       //                     : FIQ
    VECTOR 15       //                     : SError

// Common stub: gather the exception syndrome and hand off to the C handler. We never return to the
// faulting context (there is nothing to recover to), so no register state is preserved — em_exception
// prints and halts. SP is SP_EL1 (the boot stack, 16-aligned), so the C call's ABI is satisfied.
exc_common:
    mrs     x1, esr_el1          // exception syndrome (EC in [31:26])
    mrs     x2, elr_el1          // faulting instruction address
    mrs     x3, far_el1          // faulting data address (for aborts)
    bl      em_exception
0:  wfe
    b       0b
