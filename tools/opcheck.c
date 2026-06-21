// opcheck.c — the codec half of `make opcheck` (a build-time dev tool, not shipped in emberc).
// It proves the operand CODEC is self-consistent: that encode∘decode is the identity for every
// operand kind, that each opcode's spec round-trips as a whole instruction, and that the declared
// total width matches what the codec actually reads. Paired with the -DEMBER_OPCHECK VM build
// (which proves every handler CONSUMES exactly the spec width over the whole corpus), this closes
// the loop on the narrow-operand class: encoder ↔ decoder ↔ disassembler ↔ VM all derive from the
// one opcode spec, and a mismatch is a build-time failure, not a far-away runtime desync.
//
// Mirror drift this catches: a kind whose write and read disagree on width or endianness; an
// opcode whose spec arity/widths don't round-trip; opcode_operand_bytes diverging from the codec.

#include "opcode.h"
#include <stdio.h>

static int g_fail = 0;
#define FAILF(...) do { fprintf(stderr, "opcheck: FAIL — " __VA_ARGS__); \
                        fputc('\n', stderr); g_fail++; } while (0)

// The largest value a kind can hold (so a fixed kind is only tested in range; a value past its
// width would be truncated by design).
static uint32_t kind_cap(OperandKind k) {
    switch (k) {
        case OPK_U8:    return 0xFFu;
        case OPK_U16:
        case OPK_OFF16: return 0xFFFFu;
        case OPK_U24:   return 0xFFFFFFu;
        case OPK_IDX:   return 0xFFFFFFFFu;
    }
    return 0u;
}

// Round-trip a single operand kind across a ladder of magnitudes (including the LEB128 7-bit
// boundaries), asserting the value survives and write/read/width all agree on the byte span.
static void check_kind(OperandKind k) {
    uint32_t cap = kind_cap(k);
    uint32_t ladder[] = { 0u, 1u, 127u, 128u, 255u, 256u, 16383u, 16384u, 65535u, 65536u,
                          0xFFFFFFu, 0x1000000u, 0x7FFFFFFFu, 0xFFFFFFFFu };
    for (size_t i = 0; i < sizeof(ladder) / sizeof(ladder[0]); i++) {
        uint32_t v = ladder[i];
        if (v > cap) { continue; }
        uint8_t buf[8] = {0};
        uint8_t *wp = buf;
        operand_write(&wp, k, v);
        int w = operand_width(k, buf);
        if ((int)(wp - buf) != w) {
            FAILF("kind %d value %u: write advanced %d, width says %d", (int)k, v, (int)(wp - buf), w);
            continue;
        }
        const uint8_t *rp = buf;
        uint32_t got = operand_read(&rp, k);
        if ((int)(rp - buf) != w) {
            FAILF("kind %d value %u: read advanced %d, width says %d", (int)k, v, (int)(rp - buf), w);
        }
        if (got != v) {
            FAILF("kind %d: round-trip got %u, wrote %u", (int)k, got, v);
        }
    }
}

// A representative in-range value for a kind, for the whole-opcode round-trip.
static uint32_t kind_test_value(OperandKind k) {
    switch (k) {
        case OPK_U8:    return 0xABu;
        case OPK_U16:
        case OPK_OFF16: return 0xABCDu;
        case OPK_U24:   return 0xABCDEFu;
        case OPK_IDX:   return 0x0DEADBEu;   // a multi-byte varint
    }
    return 0u;
}

// Round-trip a whole opcode's operand sequence, and confirm the codec's total width agrees with
// opcode_operand_bytes(op) — so the disassembler's advance can never disagree with the codec.
static void check_opcode(OpCode op) {
    const OperandSpec *s = opcode_spec(op);
    if (s == NULL) { FAILF("%s: no spec", opcode_name(op)); return; }
    if (s->count > EMBER_MAX_OPERANDS) {
        FAILF("%s: operand count %d exceeds EMBER_MAX_OPERANDS", opcode_name(op), (int)s->count);
        return;
    }
    uint8_t buf[64] = {0};
    uint8_t *wp = buf;
    uint32_t vals[EMBER_MAX_OPERANDS];
    for (int i = 0; i < s->count; i++) {
        vals[i] = kind_test_value(s->kinds[i]) ^ (uint32_t)i;   // distinct per operand, in range
        vals[i] &= kind_cap(s->kinds[i]);
        operand_write(&wp, s->kinds[i], vals[i]);
    }
    const uint8_t *rp = buf;
    for (int i = 0; i < s->count; i++) {
        uint32_t got = operand_read(&rp, s->kinds[i]);
        if (got != vals[i]) {
            FAILF("%s: operand %d round-trip got %u, wrote %u", opcode_name(op), i, got, vals[i]);
        }
    }
    if ((int)(rp - buf) != opcode_operand_bytes_at(op, buf)) {
        FAILF("%s: codec read %d bytes, opcode_operand_bytes_at says %d", opcode_name(op),
              (int)(rp - buf), opcode_operand_bytes_at(op, buf));
    }
}

int main(void) {
    for (int k = OPK_U8; k <= OPK_IDX; k++) {
        check_kind((OperandKind)k);
    }
    for (int op = 0; op < OP__COUNT; op++) {
        check_opcode((OpCode)op);
    }
    if (g_fail) {
        fprintf(stderr, "opcheck: codec round-trip FAILED (%d issue(s))\n", g_fail);
        return 1;
    }
    printf("opcheck: codec round-trip clean — %d opcodes, every operand kind "
           "encode↔decode↔width consistent.\n", (int)OP__COUNT);
    return 0;
}
