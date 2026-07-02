//
// timer.c — GICv2 + the ARM generic timer, the first INTERRUPT source on bare metal (kernel
// milestone 4; docs/design/kernel-freestanding.md). A periodic timer IRQ, taken through the vector
// table's IRQ entry (kernel/vectors.S) and handled here, increments a tick counter that Ember can
// observe — proving asynchronous interrupts work. This is the gateway to a scheduler.
//
// Targets the QEMU `virt` board's GICv2 (run with -machine virt,gic-version=2): distributor at
// 0x0800_0000, CPU interface at 0x0801_0000. The EL1 non-secure physical timer (CNTP) is PPI 14 =
// INTID 30.
//
#include "em_platform.h"

#define GICD_BASE 0x08000000u
#define GICC_BASE 0x08010000u
#define GICD_CTLR       ((volatile uint32_t *)(GICD_BASE + 0x000))   // distributor control
#define GICD_ISENABLER0 ((volatile uint32_t *)(GICD_BASE + 0x100))   // set-enable, INTIDs 0..31
#define GICD_IPRIORITYR ((volatile uint8_t  *)(GICD_BASE + 0x400))   // per-INTID priority (byte)
#define GICC_CTLR       ((volatile uint32_t *)(GICC_BASE + 0x000))   // CPU interface control
#define GICC_PMR        ((volatile uint32_t *)(GICC_BASE + 0x004))   // priority mask
#define GICC_IAR        ((volatile uint32_t *)(GICC_BASE + 0x00C))   // interrupt acknowledge (read)
#define GICC_EOIR       ((volatile uint32_t *)(GICC_BASE + 0x010))   // end of interrupt (write)

#define TIMER_INTID 30u    // EL1 non-secure physical timer PPI

static volatile uint64_t g_ticks   = 0;
static uint64_t          g_interval = 0;


static uint64_t timer_freq(void) {
    uint64_t v;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v));
    return v;
}


static void timer_set_tval(uint64_t t) {
    __asm__ volatile("msr cntp_tval_el0, %0" :: "r"(t));
}


static void timer_set_ctl(uint64_t c) {
    __asm__ volatile("msr cntp_ctl_el0, %0" :: "r"(c));
}


// timer_init — bring up the GIC + the generic timer + unmask IRQs, so a periodic timer interrupt
// starts firing. Called by Ember as a direct extern (kernel/timerdemo.em). ~10 ticks/second.
void timer_init(void) {
    *GICD_CTLR        = 1;                     // enable the distributor
    *GICD_ISENABLER0  = (1u << TIMER_INTID);   // enable the timer PPI
    GICD_IPRIORITYR[TIMER_INTID] = 0x00;       // highest priority
    *GICC_PMR         = 0xFF;                   // allow all priorities through the CPU interface
    *GICC_CTLR        = 1;                       // enable the CPU interface

    uint64_t freq = timer_freq();
    if (freq == 0) {                             // firmware left CNTFRQ unset (never on QEMU virt);
        freq = 62500000;                         // fall back to QEMU virt's 62.5 MHz rather than /0
    }
    g_interval = freq / 10;                      // ~100 ms per tick
    timer_set_tval(g_interval);
    timer_set_ctl(1);                            // ENABLE=1, IMASK=0
    __asm__ volatile("isb");                     // synchronise the timer config before unmasking

    __asm__ volatile("msr daifclr, #2");         // unmask IRQs (clear PSTATE.I)
}


// em_irq — the C interrupt handler, called from the vector table's IRQ entry (vectors.S). Acknowledge
// the interrupt, and if it is our timer, bump the tick count and re-arm the countdown; then signal
// end-of-interrupt. IRQs are masked by the CPU for the duration, so there is no re-entrancy here.
void em_irq(void) {
    uint32_t iar   = *GICC_IAR;
    uint32_t intid = iar & 0x3FFu;
    if (intid == TIMER_INTID) {
        g_ticks++;
        timer_set_tval(g_interval);              // re-arm: this DEASSERTS the level-triggered timer
                                                 // line (ISTATUS clears when TVAL>0), so it must come
                                                 // BEFORE EOIR — EOIR with the line still asserted
                                                 // would immediately re-pend (an interrupt storm).
    }
    // Complete the tick store + the timer re-arm before signalling end-of-interrupt, so the deassert
    // is observed by the GIC first (a DSB matters on a real out-of-order core; a no-op on QEMU TCG).
    __asm__ volatile("dsb sy" ::: "memory");
    *GICC_EOIR = iar;                            // end of interrupt
}


// tick_count — the timer tick count so far, for Ember to poll (a direct extern). It only ever
// advances via em_irq, so a program seeing it change has observed a real hardware interrupt.
int64_t tick_count(void) {
    return (int64_t)g_ticks;
}
