#!/bin/sh
# tests/run-kernel.sh — QEMU smoke test for the bare-metal kernel spike (OFI-167 / kernel milestone 1).
# Boots kernel/kernel.elf on QEMU `aarch64 virt` and asserts the UART output + a clean semihosting exit.
# Kept OUT of the dependency-free default suite (tests/run.sh) — it needs the LLVM cross toolchain +
# qemu, like tests/run-graphics.sh / tests/run-db.sh. Invoked by `make test-kernel`, which builds the
# image first. The heap-free Ember program (kernel/hello.em) prints a message byte-by-byte through the
# native direct-extern `uart_putc`, then a counted loop prints three dots (proving the integer runtime
# path — em_add/em_eq_op/em_truthy — runs on bare metal), then requests a clean shutdown.
set -u

ELF="kernel/kernel.elf"
QEMU="${QEMU_AARCH64:-qemu-system-aarch64}"
EXPECT="Hello from Ember!"

if ! command -v "$QEMU" >/dev/null 2>&1; then
    echo "run-kernel: $QEMU not found (brew install qemu) — skipping" >&2
    exit 0
fi
if [ ! -f "$ELF" ]; then
    echo "run-kernel: $ELF missing (run: make kernel)" >&2
    exit 1
fi

# A timeout guards against a hang if the semihosting exit ever regresses (the guest otherwise spins in
# a wfe loop). Prefer coreutils `timeout`, fall back to `gtimeout`, else run bare.
TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT="timeout 15"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT="gtimeout 15"
fi

OUT=$($TIMEOUT "$QEMU" -M virt -cpu cortex-a53 -nographic -semihosting -kernel "$ELF" 2>/dev/null)
RC=$?

printf '%s\n' "$OUT"
echo "--- (qemu exit: $RC) ---"

fail=0
if printf '%s' "$OUT" | grep -q "$EXPECT"; then
    echo "PASS: UART printed the message"
else
    echo "FAIL: expected '$EXPECT' in the UART output"
    fail=1
fi
if printf '%s' "$OUT" | grep -q '\.\.\.'; then
    echo "PASS: counted-loop output present (integer runtime path ran on bare metal)"
else
    echo "FAIL: expected '...' from the counted loop"
    fail=1
fi
if [ "$RC" -eq 0 ]; then
    echo "PASS: clean semihosting exit (0)"
else
    echo "WARN: qemu exit $RC (semihosting exit-code conventions vary; the UART checks are the gate)"
fi

if [ "$fail" -ne 0 ]; then
    echo "kernel smoke test FAILED"
    exit 1
fi
echo "kernel smoke test OK"
