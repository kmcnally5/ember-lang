#include "opcode.h"

// Both tables are generated from the one EMBER_OPCODES list in opcode.h, so the names and operand
// specs always match the enum. The OPSn macros are defined only here (the other X-macro consumers
// ignore the third argument), so the spec lives in exactly one place.
static const char *const OPCODE_NAMES[OP__COUNT] = {
#define X(name, mnemonic, operands) [name] = mnemonic,
    EMBER_OPCODES(X)
#undef X
};

static const OperandSpec OPCODE_SPECS[OP__COUNT] = {
#define OPS0()                  { 0, { 0 } }
#define OPS1(a)                 { 1, { OPK_##a } }
#define OPS2(a, b)              { 2, { OPK_##a, OPK_##b } }
#define OPS3(a, b, c)           { 3, { OPK_##a, OPK_##b, OPK_##c } }
#define OPS5(a, b, c, d, e)     { 5, { OPK_##a, OPK_##b, OPK_##c, OPK_##d, OPK_##e } }
#define X(name, mnemonic, operands) [name] = operands,
    EMBER_OPCODES(X)
#undef X
#undef OPS0
#undef OPS1
#undef OPS2
#undef OPS3
#undef OPS5
};

const char *opcode_name(OpCode op) {
    if (op < 0 || op >= OP__COUNT) {
        return "???";
    }
    return OPCODE_NAMES[op];
}


const OperandSpec *opcode_spec(OpCode op) {
    if (op < 0 || op >= OP__COUNT) {
        return NULL;
    }
    return &OPCODE_SPECS[op];
}


int opcode_operand_bytes_at(OpCode op, const uint8_t *operands) {
    if (op < 0 || op >= OP__COUNT) {
        return 0;
    }
    const OperandSpec *s = &OPCODE_SPECS[op];
    int total = 0;
    for (int i = 0; i < s->count; i++) {
        total += operand_width(s->kinds[i], operands + total);   // `operands` must be valid for OPK_IDX
    }
    return total;
}
