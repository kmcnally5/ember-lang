/*
 * kernel.ld — link the bare-metal image for the QEMU `virt` board (OFI-167 / kernel milestone 1).
 *
 * QEMU's `-kernel` loads an ELF per its program headers and enters at ENTRY. We place the boot stub
 * (.text.boot, holding _start) first at the board's load address 0x4008_0000, then the rest of the
 * code and data. RAM on `virt` starts at 0x4000_0000; the loader puts a flat kernel at +0x80000.
 */
ENTRY(_start)

SECTIONS
{
    . = 0x40080000;

    .text : {
        KEEP(*(.text.boot))     /* _start must be first, at the entry address */
        *(.text*)
    }

    .rodata : { *(.rodata*) }
    .data   : { *(.data*) }

    .bss : {
        *(.bss*)
        *(COMMON)
    }

    . = ALIGN(16);
}
