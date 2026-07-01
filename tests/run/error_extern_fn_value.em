// error_extern_fn_value.em — a foreign (extern "c") function has NO bytecode slot (fn_index == -1),
// so it cannot be taken as a function value: doing so would close over index -1 and crash the VM (a
// closure over a bogus function). Both hosted-registry externs (like `sin`) and native direct-externs
// (OFI-167) are rejected the same way. Regression guard for OFI-168 (found by the OFI-167 review).
extern "c" {
    fn sin(x: f64) -> f64
}


fn main() -> int {
    let f = sin
    return 0
}
