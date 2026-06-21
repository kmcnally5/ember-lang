// ops.em — exercises every arithmetic opcode the current slice emits
// (CONST, ADD, SUB, MUL, DIV, MOD, NEG, RETURN) so the disassembly golden is a
// regression anchor for the bytecode the compiler produces.
fn main() -> int {
    return 1 + 2 - 3 * 4 / 5 % 6 - -7
}
