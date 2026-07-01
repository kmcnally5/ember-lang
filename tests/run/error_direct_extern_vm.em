// error_direct_extern_vm.em — a DIRECT extern (OFI-167): a C symbol not in the hosted FFI registry,
// e.g. a kernel MMIO helper. The checker accepts it (native emits a direct call, linker-resolved),
// but the bytecode VM has no binding for such a symbol, so `--emit=run` rejects it with a clear
// message pointing at the native path. It compiles + links only via `emberc --emit=c` / `-o`.
extern "c" {
    fn uart_putc(c: i32)
}


fn main() -> int {
    uart_putc(65)
    return 0
}
