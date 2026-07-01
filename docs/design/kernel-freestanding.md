# Kernel / freestanding runtime — kickoff brief + milestone log

> **Status: MILESTONE 1 ACHIEVED (2026-07-01).** A heap-free Ember `main` boots on QEMU `aarch64 virt`
> and prints to the PL011 UART with **no libc and no heap** — "Hello from Ember!" over the wire, plus a
> counted loop proving the integer runtime path runs on bare metal. Gated by `make test-kernel`. The
> forks below were confirmed with Karl (aarch64 virt · Apple clang cross · UART-hello, hand-shim first);
> the outcome + the three real discoveries are recorded in **"Milestone 1 — outcome"** at the end. The
> original plan is kept as written for the record.

## Why now

Writing an **OS kernel in Ember** is the north star (see [[ember-kernel-endgame]] in memory / MANIFESTO). The
self-hosting campaign was the maturity play and it's done: the native **C-emit backend** (`selfhost/cgen_c.em`,
`emberc --emit=c` / `-o`) now reproduces the whole compiler byte-identical **and rebuilds itself into a
native binary**. That C-emit backend is the **on-ramp to bare-metal codegen** — the same AST→C path, but
producing code that runs with **no OS and no libc**.

## The gaps between "compiles to C" and "boots on bare metal"

1. **Freestanding runtime.** The current `em_*` runtime (`src/runtime.c`, `src/vm.c`) uses `malloc`/`free`,
   `printf`/stdio, `pthread`, etc. Bare metal has none of these. A freestanding target needs either **no
   runtime at all** (a scalar-only subset) or a **tiny freestanding runtime** (a bump allocator over a fixed
   region, no stdio, MMIO for output).
2. **A low/no-alloc language subset.** A kernel can't lean on a general heap for everything. We want to know
   *exactly* which Ember constructs need the allocator (strings, arrays, boxed structs, enums with payloads,
   closures) vs which are heap-free (scalars, value structs, `extern "c"` calls). The first spike stays
   entirely in the heap-free subset.
3. **Bare-metal codegen.** A `--freestanding` / `--target=bare` emit mode: no libc includes, a custom entry
   (`_start` / `kmain`), and MMIO instead of stdio. Most of the AST→C machinery is reused unchanged; the
   difference is the *preamble* (includes, runtime shims) and the *entry*.
4. **MMIO + a boot stub.** Reading/writing hardware registers (via `extern "c"` C helpers to start, an
   intrinsic later) and a tiny assembly `_start` that sets up a stack and branches to Ember `main`.

## Toolchain reality (checked 2026-07-01 on Karl's arm64 Mac)

- **Apple clang cross-compiles bare-metal aarch64 with zero extra install:**
  `clang -target aarch64-none-elf -ffreestanding -nostdlib …` works. **No cross-gcc needed.**
- **`qemu-system-aarch64` is NOT installed** → `brew install qemu` (per "install the tool, don't work
  around"). This is the only missing piece.
- **`extern "c"` FFI reaches the native C-emit backend** (`examples/16_ffi.em`) — so an Ember program can
  `extern "c" fn uart_putc(c: i32)` and we supply the C body in the freestanding shim. That is the MMIO
  output mechanism for the first spike.

## Design forks to confirm FIRST (in the kernel chat)

1. **Target board.** **Recommended: QEMU `aarch64 virt`** — matches Karl's arm64 Mac, trivial to install,
   a well-documented **PL011 UART** at `0x0900_0000` for output, RAM at `0x4000_0000`, `-kernel` loads a flat
   binary at `0x4008_0000`. Alternatives: `riscv virt` (simplest ISA, also fine) or x86_64 (more boot
   ceremony — BIOS/multiboot). arm64 virt is the least-friction path to first light.
2. **Toolchain.** **Recommended: Apple clang cross** (`-target aarch64-none-elf -ffreestanding -nostdlib`),
   already present — vs a `brew install`ed `aarch64-elf-gcc`. Clang cross is zero-install.
3. **First-spike scope.** **Recommended: UART "hello" only** — the smallest program that exercises the WHOLE
   seam (freestanding codegen → boot stub → linker script → QEMU → MMIO). Defer the allocator, exceptions,
   and interrupts until "hello" boots.

## The first milestone — "Hello from Ember on bare metal"

A minimal Ember program compiled through a freestanding path that **boots on QEMU `aarch64 virt` and prints a
string to the PL011 UART**, with **no libc and no heap**. This proves the entire toolchain seam; everything
after (allocator, interrupts, the no-alloc subset, a richer runtime) is incremental.

### Concrete steps to first light

1. `brew install qemu` (the only missing tool).
2. **Heap-free Ember source** (`kernel/hello.em` or similar): a `main` that calls `extern "c" fn uart_putc`
   in a loop over the bytes of a message. First cut can even hardcode the bytes (no string type) to stay
   100% heap-free; a fixed-size byte array is the next step.
3. **Freestanding emit.** Start the SIMPLEST way possible before touching the compiler: hand-write a tiny
   `kernel/rt.c` shim (`uart_putc` writing to `*(volatile uint32_t*)0x09000000 = c;`, plus any `em_*`
   stubs the emitted C references for the heap-free subset — ideally none) and compile the stock
   `emberc --emit=c hello.em` output against it with `-ffreestanding -nostdlib`. If the emitted C pulls in
   libc/runtime the heap-free subset shouldn't need, that tells us exactly what a `--freestanding` preamble
   must strip — the first real compiler task.
4. **Boot stub + linker script.** `kernel/boot.S` (aarch64 `_start`: set `sp`, `bl main`, then spin) and
   `kernel/kernel.ld` (entry `_start`, `.text`/`.rodata`/`.data`/`.bss` from `0x40080000`).
5. **Link + run.** `clang -target aarch64-none-elf -ffreestanding -nostdlib -T kernel.ld boot.S hello.c rt.c
   -o kernel.elf`; `qemu-system-aarch64 -M virt -cpu cortex-a53 -nographic -kernel kernel.elf`.
6. **Verify.** QEMU's stdout shows the message (the PL011 UART is wired to the terminal under `-nographic`).

### Then, incrementally (post-hello, separate milestones)

- A **`--freestanding` emit mode** in `main.c` / `cgen_c` (strip libc includes, emit `_start` glue or a
  documented entry contract) so the C-emit path targets bare metal directly, not via a hand-shim.
- Map the **heap-free subset** precisely (which constructs emit `em_*` runtime calls) → a **tiny freestanding
  runtime** (a bump allocator over a fixed `.bss` arena, no stdio) to unlock strings/arrays/structs on bare
  metal.
- **MMIO/asm intrinsics** (volatile load/store, barriers) so hardware access isn't via `extern "c"` forever.
- Interrupts / the exception vector table; a timer; then the actual kernel surface (memory map, a trivial
  scheduler) — all in Ember.

## Guardrails (from MANIFESTO / CLAUDE.md)

- Default build stays **dependency-free**; the kernel target is **opt-in** (a build flag / separate make
  target), like `make graphics` / `make net`.
- Every increment lands with a **runnable** artifact + a test (a QEMU-run smoke test that greps the UART
  output), mirroring the differential discipline that carried self-hosting.
- Freestanding codegen is a **new emit target**, not a rewrite — reuse the AST→C machinery; the delta is the
  preamble + entry + which runtime symbols exist.

## Milestone 1 — outcome (2026-07-01): "Hello from Ember on bare metal" ✅

`make test-kernel` boots `kernel/kernel.elf` on QEMU `aarch64 virt` and the PL011 UART prints:

```
Hello from Ember!
...
```

emitted by the heap-free `kernel/hello.em` — a message written byte-by-byte through `uart_putc`, then a
counted loop (the three dots) that exercises the integer runtime (`em_add`/`em_eq_op`/`em_truthy`) with no
OS underneath. The pipeline: default `emberc --emit=c` → freestanding shim (`kernel/rt.c` + shadow
`kernel/ember_rt.h`) → boot stub (`kernel/boot.S`) → linker script (`kernel/kernel.ld`) → QEMU. Opt-in
(`make kernel` / `make test-kernel`); the default build stays dependency-free.

### The three real discoveries (each changed the plan)

1. **`extern "c"` couldn't reach bare metal at all → native direct-extern (OFI-167).** The FFI was a
   *closed, index-keyed registry* of hosted libc/libm symbols — both the VM and the C-emit backend
   dispatched every extern through `em_ffi(&g_em, <index>, …)`, so the C symbol name never reached the
   output. There was no way to call a `uart_putc`. **Fix (the "real fix", chosen over a registry stopgap):**
   an `extern "c"` fn NOT in the registry is a *direct extern* — the native backend forward-declares it with
   its exact C type and emits a direct call to the named symbol (linker-resolved against `rt.c`); the VM
   rejects it as native-only. Scalar/Ptr params + return for now (string/buffer/struct still need a registry
   entry). This is the general mechanism the kernel needs: declare any driver helper and call it.
2. **"Zero-install" needed one install: an ELF linker.** Apple clang *compiles* `aarch64-none-elf`
   zero-install, but the default linker is Mach-O-only `ld64` — it can't link ELF or honour a linker script.
   `brew install lld` (LLVM's own linker, same toolchain family) supplies `ld.lld`; the link uses
   `--ld-path=$(command -v ld.lld)`. So the toolchain is **Apple clang cross + lld + qemu**, not purely
   zero-install.
3. **FP/SIMD must be enabled at EL1 before any non-trivial Ember runs.** The runtime's 16-byte `Value`
   (its union holds a `double`) is copied by clang with **128-bit SIMD loads/stores**, but FP/SIMD access
   *traps at reset*. The constant message bytes materialised into GP registers and printed; the loop's
   runtime `Value` copies hit a `q`-register and took an "SIMD trapped" exception (ESR EC=0x7) into an empty
   vector → hang. `boot.S` now sets `CPACR_EL1.FPEN = 0b11` before calling `main`. **Mandatory for any
   bare-metal Ember target** — worth remembering as the runtime grows.

### Files

`kernel/hello.em` (source) · `kernel/rt.c` + `kernel/ember_rt.h` (freestanding shim — the exact `em_*`
surface the heap-free subset references) · `kernel/boot.S` (aarch64 `_start`: park secondaries, enable
FP/SIMD, set sp, call `main`, semihosting `SYS_EXIT`) · `kernel/kernel.ld` (load at `0x4008_0000`) ·
`tests/run/error_direct_extern_vm.em` (the VM-rejection golden).

### Milestone 1b — `--freestanding` emit mode ✅ (2026-07-01, same day)

`emberc --emit=c --freestanding` is now a first-class emit mode (`src/main.c` + `src/cgen_c.c`):

- **A bare `int main(void)` entry** — no argc/argv, no `printf` result-echo, no exit heap sweep — that
  **returns Ember main's int result as the exit code**. `boot.S` forwards it through the semihosting exit
  block, so the QEMU exit code is a value **computed by Ember on bare metal**: `hello.em` returns its loop
  counter and `make test-kernel` asserts `qemu exit == 3`. The verification loop closes over a computed
  value, not just printed text.
- **Emit-time rejection of hosted-only constructs** with clear messages instead of late link errors:
  `spawn`/`nursery` (needs pthreads — a kernel IS its own scheduler) and **hosted-registry extern calls**
  (`sin`, `fopen`, … dispatch via `em_ffi` + the in-tree registry, which needs libc; only direct externs
  reach bare metal). Both are regression-checked by `tests/run-kernel.sh`. Everything else outside the
  heap-free subset still fails honestly at link time by symbol name.
- **Flag hygiene:** `--freestanding` pairs with `--emit=c` only; with `-o` (which links the hosted
  runtime) or any other emit mode it's a usage error (exit 64).
- **The include-shadow stays deliberately.** The emitted C still says `#include "ember_rt.h"`, resolved to
  `kernel/ember_rt.h` via `-Ikernel` — ONE definition of the ABI per build, no drift between an inline
  preamble and the shim (this is how C swaps runtimes; newlib vs glibc do the same). What changed is that
  the freestanding entry no longer *references* hosted symbols, so the shim shrank to its true contract:
  `Value` + `EmberRt` + `em_add`/`em_eq_op`/`em_truthy`/`em_panic` + `uart_putc` + `memcpy`/`memset`.
  The `printf` stub, `em_argc`/`em_argv`, `rt_free_objects`, and the string-echo machinery are GONE.
- Default `--emit=c` output is **byte-unchanged** (the self-hosting reproduction fixed point holds:
  1213/0), and the golden suite is 428/0.

## Milestone 2 — a heap on bare metal: the REAL runtime, freestanding ✅ (2026-07-02)

`make test-kernel` now boots a program that uses **arrays, strings, string interpolation, and
`println`** on bare metal:

```
Hello from Ember — running on bare metal with a heap!
sum of [10, 20, 12] = 42
```

exit code **42** (the array sum, computed by Ember). This required moving from the M1 hand-shim to the
**canonical `src/runtime.c`, compiled `-DEMBER_FREESTANDING`** — so bare metal runs the *same* runtime
the hosted VM/native backends do, not a fork (no drift; the reason the M1 shim is now deleted).

- **The platform layer** (`include/em_platform.h` + `kernel/platform.c`): the libc subset the runtime is
  written against, for a target with no libc. A **bump allocator** over a fixed 16 MiB `.bss` arena
  (size-prefixed blocks so `realloc` works; `free` is a no-op — a batch/kernel model), byte-wise
  `memcpy`/`memmove`/`memset`/`memcmp`/`strlen`, a **minimal `printf` family** (`snprintf`/`vsnprintf`/
  `fprintf`/`fwrite`) routed to the UART, and `exit`/`abort` → halt. `ember_rt.h` includes it under
  `EMBER_FREESTANDING` instead of `<stdio.h>`/`<stdlib.h>`/`<string.h>`.
- **runtime.c guards** (all `#ifdef EMBER_FREESTANDING`, so the hosted build is byte-identical): the
  hosted-only builtins fall through to the runtime's own "unsupported builtin" panic — stdin/file I/O,
  `strtod`, libm `sqrt`/`pow`/…, PRNG, `getenv`, the wall clock, `em_ffi` (the registry FFI; only direct
  externs reach bare metal). The freestanding-safe builtins stay: array/string ops, `hash`, `concat`,
  `char_code`, `byte_slice`, `exit`. The double-drop `backtrace` detector was already build-gated.
- **The MMU is now on** (`kernel/platform.c` `mmu_init`, called from `boot.S`). With the MMU off, every
  data access is Device memory and **faults on any unaligned access** — which the runtime does
  constantly (packed fields, 16-byte `Value` `ldp`/`stp`). A minimal flat identity map (one L1 table,
  1 GiB block descriptors: RAM `0x4000_0000` = Normal cacheable, low 1 GiB = Device for the UART) fixes
  it and turns on the caches. Diagnosed from a Data Abort with DFSC=0x21 (alignment) under `qemu -d int`.

Gates: `make test` 428/0, `make selfhost` 1213/0 (the reproduction fixed point holds — the runtime
guards changed no hosted codegen), ASan clean, `make test-kernel` PASS (exit 42, output asserted).

## Milestone 3 — an exception vector table: faults print, not hang ✅ (2026-07-02)

Every CPU fault so far (the M1 FP/SIMD trap, the M2 alignment fault) presented as a *silent hang* — the
CPU branched into an empty vector and spun. Now `kernel/vectors.S` installs the full 16-entry aarch64
EL1 vector table (2 KiB-aligned per `VBAR_EL1`, each entry 0x80 bytes), routing every exception to a
common stub that reads `ESR_EL1`/`ELR_EL1`/`FAR_EL1` and calls `em_exception` (`kernel/platform.c`),
which prints a **kernel panic** and halts:

```
*** EMBER KERNEL PANIC: CPU exception ***
  vector=4 (sync)  EC=0x3c  ESR=0xf2000000  ELR=0x40086b2c  FAR=0x0
  halted.
```

`boot.S` sets `VBAR_EL1` as soon as the stack is up (before `mmu_init`), so even a setup-time fault is
reported. The **fault-vector regression** is a second image, `kernel/faultdemo.elf` (from
`kernel/faultdemo.em`), which deliberately executes a `BRK` via the `cpu_break` direct extern;
`make test-kernel` boots it and asserts the panic banner + the decoded syndrome (`EC=0x3c`, a BRK).
`EC` is the field that matters — `0x25` data abort, `0x07` SIMD/FP trapped, `0x3c` BRK — so a future
fault is a one-line diagnosis instead of a mystery.

### Next increments

- **A timer + interrupts** (`em_clock` returns 0 today) — configure the GIC + the generic timer, take an
  IRQ through the (already-present) IRQ vector, and drive a periodic tick. The gateway to a **scheduler**,
  which is the kernel proper.
- **Widen the freestanding math/util surface** (soft-float `sqrt`/`floor`; a PRNG seeded off the timer) —
  currently they panic as "unsupported".
- **MMIO/asm intrinsics** (volatile load/store — retires the `extern "c"` shim for hardware access), then
  the first real driver surface, all in Ember.
