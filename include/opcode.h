#ifndef EMBER_OPCODE_H
#define EMBER_OPCODE_H

#include <stdint.h>
#include <stddef.h>

// The single source of truth for Ember's bytecode instruction set.
//
// Each row is  X(enum-name, "mnemonic", OPERANDS)  where OPERANDS is OPS0()..OPS5(...) listing each
// inline operand's KIND in stream order (OperandKind below). One declaration drives four things that
// must agree or the VM desyncs far from the cause: the operand WIDTHS the disassembler advances by,
// the bytes codegen WRITES, the bytes the VM READS, and the round-trip codec. They share one codec
// keyed by these kinds, so they cannot drift — the class behind OFI-007/047/056 (a narrow operand
// silently wrapping). `make opcheck` proves the codec round-trips AND that every VM handler consumes
// exactly what its spec declares, across the whole test corpus.
//
// Drift is further caught at compile time: codegen and the VM switch over OpCode with no `default:`
// arm, so -Wswitch (-Wall -Werror) fails the build the moment an opcode added here lacks a handler.

// OperandKind — the SHAPE of one inline operand in the byte stream. Widths are decoded through the
// codec (operand_read / operand_width) so every consumer reads them identically (big-endian).
typedef enum {
    OPK_U8,      // a raw byte: a small fixed kind-tag (numeric width, render kind, array elem kind)
    OPK_U16,     // a 16-bit big-endian value (legacy fixed; index operands now use OPK_IDX)
    OPK_U24,     // a 24-bit big-endian value (legacy fixed)
    OPK_OFF16,   // a 16-bit big-endian jump distance (fixed width — back-patched; not an index)
    OPK_IDX,     // an unbounded index/count/slot/id as unsigned LEB128 (1 byte for values < 128).
                 // The modern, cap-free encoding for every pool index, local slot, field index,
                 // struct/enum/function id, and count — no value can overflow it (OFI-007/047/056).
} OperandKind;

#define EMBER_MAX_OPERANDS 5   // FOR_ARRAY has the most: arr, idx, len, var slots + the exit offset

#define EMBER_OPCODES(X)                                          \
    X(OP_CONST,         "CONST",         OPS1(IDX))               \
    X(OP_STRING,        "STRING",        OPS1(IDX))               \
    X(OP_TRUE,          "TRUE",          OPS0())                  \
    X(OP_FALSE,         "FALSE",         OPS0())                  \
    X(OP_POP,           "POP",           OPS0())                  \
    X(OP_DUP,           "DUP",           OPS0())                  \
    X(OP_GET_LOCAL,     "GET_LOCAL",     OPS1(IDX))               \
    X(OP_SET_LOCAL,     "SET_LOCAL",     OPS1(IDX))               \
    X(OP_ADD,           "ADD",           OPS1(U8))                \
    X(OP_SUB,           "SUB",           OPS1(U8))                \
    X(OP_MUL,           "MUL",           OPS1(U8))                \
    X(OP_DIV,           "DIV",           OPS1(U8))                \
    X(OP_MOD,           "MOD",           OPS1(U8))                \
    X(OP_NEG,           "NEG",           OPS1(U8))                \
    X(OP_NOT,           "NOT",           OPS0())                  \
    X(OP_BITAND,        "BITAND",        OPS0())                  \
    X(OP_BITOR,         "BITOR",         OPS0())                  \
    X(OP_BITXOR,        "BITXOR",        OPS0())                  \
    X(OP_BITNOT,        "BITNOT",        OPS1(U8))                \
    X(OP_SHL,           "SHL",           OPS1(U8))                \
    X(OP_SHR,           "SHR",           OPS1(U8))                \
    X(OP_WRAP_ADD,      "WRAP_ADD",      OPS1(U8))                \
    X(OP_WRAP_SUB,      "WRAP_SUB",      OPS1(U8))                \
    X(OP_WRAP_MUL,      "WRAP_MUL",      OPS1(U8))                \
    X(OP_EQ,            "EQ",            OPS0())                  \
    X(OP_NEQ,           "NEQ",           OPS0())                  \
    X(OP_LT,            "LT",            OPS1(U8))                \
    X(OP_LE,            "LE",            OPS1(U8))                \
    X(OP_GT,            "GT",            OPS1(U8))                \
    X(OP_GE,            "GE",            OPS1(U8))                \
    X(OP_JUMP,          "JUMP",          OPS1(OFF16))             \
    X(OP_JUMP_IF_FALSE, "JUMP_IF_FALSE", OPS1(OFF16))             \
    X(OP_LOOP,          "LOOP",          OPS1(OFF16))             \
    X(OP_FOR_RANGE,     "FOR_RANGE",     OPS3(IDX, IDX, OFF16))   \
    X(OP_FOR_ARRAY,     "FOR_ARRAY",     OPS5(IDX, IDX, IDX, IDX, OFF16)) \
    X(OP_CALL,          "CALL",          OPS2(IDX, IDX))          \
    X(OP_CALL_NATIVE,   "CALL_NATIVE",   OPS2(IDX, IDX))          \
    X(OP_CALL_C,        "CALL_C",        OPS2(IDX, IDX))          \
    X(OP_CALL_INDIRECT, "CALL_INDIRECT", OPS1(IDX))              \
    X(OP_MAKE_DYN,      "MAKE_DYN",      OPS0())                  \
    X(OP_CALL_DYN,      "CALL_DYN",      OPS2(IDX, IDX))          \
    X(OP_MAKE_CLOSURE,  "MAKE_CLOSURE",  OPS2(IDX, IDX))          \
    X(OP_CALL_CLOSURE,  "CALL_CLOSURE",  OPS1(IDX))              \
    X(OP_NEW_STRUCT,    "NEW_STRUCT",    OPS2(IDX, IDX))          \
    X(OP_NEW_ENUM,      "NEW_ENUM",      OPS3(IDX, IDX, IDX))     \
    X(OP_GET_FIELD,     "GET_FIELD",     OPS1(IDX))              \
    X(OP_GET_FIELD_OWNED, "GET_FIELD_OWNED", OPS1(IDX))          \
    X(OP_DROP_UNDER,    "DROP_UNDER",    OPS0())                  \
    X(OP_PICK,          "PICK",          OPS1(IDX))              \
    X(OP_NEW_STRUCT_ARRAY, "NEW_STRUCT_ARRAY", OPS2(IDX, IDX))   \
    X(OP_UNBOX_STRUCT,  "UNBOX_STRUCT",   OPS1(IDX))             \
    X(OP_UNBOX_STRUCT_BORROW, "UNBOX_STRUCT_BORROW", OPS1(IDX))  \
    X(OP_BOX_STRUCT,    "BOX_STRUCT",     OPS1(IDX))             \
    X(OP_SET_FIELD,     "SET_FIELD",     OPS1(IDX))              \
    X(OP_GET_TAG,       "GET_TAG",       OPS0())                 \
    X(OP_NEW_ARRAY,     "NEW_ARRAY",     OPS2(IDX, U8))          \
    X(OP_INDEX,         "INDEX",         OPS0())                 \
    X(OP_SET_INDEX,     "SET_INDEX",     OPS0())                 \
    X(OP_ARRAY_LEN,     "ARRAY_LEN",     OPS0())                 \
    X(OP_ARRAY_APPEND,  "ARRAY_APPEND",  OPS0())                 \
    X(OP_ARRAY_POP,     "ARRAY_POP",     OPS0())                 \
    X(OP_ARRAY_REMOVE_AT, "ARRAY_REMOVE_AT", OPS0())            \
    X(OP_SLICE,         "SLICE",         OPS0())                 \
    X(OP_SLICE_COPY,    "SLICE_COPY",    OPS0())                 \
    X(OP_STR_LEN,       "STR_LEN",       OPS0())                 \
    X(OP_STR_CHARS,     "STR_CHARS",     OPS0())                 \
    X(OP_STR_CHAR_COUNT,"STR_CHAR_COUNT",OPS0())                 \
    X(OP_STR_BYTES,     "STR_BYTES",     OPS0())                 \
    X(OP_STR_SPLIT,     "STR_SPLIT",     OPS0())                 \
    X(OP_STR_PARSE_INT, "STR_PARSE_INT", OPS3(IDX, IDX, IDX))    \
    X(OP_INT_TO_FLOAT,  "INT_TO_FLOAT",  OPS0())                 \
    X(OP_FLOAT_TO_INT,  "FLOAT_TO_INT",  OPS0())                 \
    X(OP_CONV,          "CONV",          OPS1(U8))               \
    X(OP_CLOCK,         "CLOCK",         OPS0())                 \
    X(OP_TO_STRING,     "TO_STRING",     OPS1(U8))               \
    X(OP_NURSERY_BEGIN, "NURSERY_BEGIN", OPS0())                 \
    X(OP_CONTRACT_CHECK,"CONTRACT_CHECK", OPS1(IDX))             \
    X(OP_SPAWN,         "SPAWN",         OPS2(IDX, IDX))         \
    X(OP_NURSERY_END,   "NURSERY_END",   OPS0())                 \
    X(OP_CHANNEL_NEW,   "CHANNEL_NEW",   OPS0())                 \
    X(OP_SEND,          "SEND",          OPS0())                 \
    X(OP_RECV,          "RECV",          OPS3(IDX, IDX, IDX))    \
    X(OP_TRY_RECV,      "TRY_RECV",      OPS3(IDX, IDX, IDX))    \
    X(OP_CLOSE,         "CLOSE",         OPS0())                 \
    X(OP_DROP,          "DROP",          OPS1(IDX))             \
    X(OP_INCREF,        "INCREF",        OPS0())                \
    X(OP_RELEASE,       "RELEASE",       OPS0())                \
    X(OP_RETURN_STRUCT, "RETURN_STRUCT", OPS1(IDX))             \
    X(OP_RETURN,        "RETURN",        OPS0())                 \
    X(OP_CONCAT,        "CONCAT",        OPS0())

typedef enum {
#define X(name, mnemonic, operands) name,
    EMBER_OPCODES(X)
#undef X
    OP__COUNT
} OpCode;

// The ordered operand kinds of one instruction (a row of the table above).
typedef struct {
    uint8_t     count;
    OperandKind kinds[EMBER_MAX_OPERANDS];
} OperandSpec;

// Mnemonic for an opcode (e.g. "CONST"), or "???" if out of range.
const char *opcode_name(OpCode op);

// The operand-kind list for `op` (NULL if out of range). The single source the codec reads.
const OperandSpec *opcode_spec(OpCode op);

// Total inline operand bytes for instruction `op` whose operands begin at `operands`. `operands` is
// read only for variable-width kinds (OPK_IDX), so it must point at the real bytes when an opcode
// carries one. This is what the disassembler advances by and what the OPCHECK build verifies against.
int opcode_operand_bytes_at(OpCode op, const uint8_t *operands);

// ---- the operand codec: ONE encode/decode keyed by OperandKind, shared by every consumer --------

// Bytes occupied by one operand of kind `k` whose first byte is at `at`. Fixed kinds ignore `at`;
// OPK_IDX reads the LEB128 continuation bits at `at` to count its bytes.
static inline int operand_width(OperandKind k, const uint8_t *at) {
    switch (k) {
        case OPK_U8:    return 1;
        case OPK_U16:   return 2;
        case OPK_OFF16: return 2;
        case OPK_U24:   return 3;
        case OPK_IDX: {
            int n = 1;
            while (at[n - 1] & 0x80) { n++; }
            return n;
        }
    }
    return 0;
}

// Decode one operand of kind `k` at `*p`, advancing `*p` past it. Fixed kinds are big-endian; OPK_IDX
// is unsigned LEB128 (7 bits per byte, low group first, high bit = "more follows").
static inline uint32_t operand_read(const uint8_t **p, OperandKind k) {
    const uint8_t *q = *p;
    uint32_t v = 0;
    switch (k) {
        case OPK_U8:                    v = q[0];                                      *p += 1; break;
        case OPK_U16:
        case OPK_OFF16:                 v = ((uint32_t)q[0] << 8) | q[1];              *p += 2; break;
        case OPK_U24: v = ((uint32_t)q[0] << 16) | ((uint32_t)q[1] << 8) | q[2];      *p += 3; break;
        case OPK_IDX: {
            int shift = 0;
            uint8_t b;
            do { b = *q++; v |= (uint32_t)(b & 0x7f) << shift; shift += 7; } while (b & 0x80);
            *p = q;
            break;
        }
    }
    return v;
}

// Encode one operand of kind `k` into `*p`, advancing `*p`. The exact inverse of operand_read — the
// SAME byte layout, so encode∘decode is the identity (proved by `make opcheck`).
static inline void operand_write(uint8_t **p, OperandKind k, uint32_t v) {
    uint8_t *q = *p;
    switch (k) {
        case OPK_U8:    q[0] = (uint8_t)v;                                                   *p += 1; break;
        case OPK_U16:
        case OPK_OFF16: q[0] = (uint8_t)(v >> 8);  q[1] = (uint8_t)v;                        *p += 2; break;
        case OPK_U24:   q[0] = (uint8_t)(v >> 16); q[1] = (uint8_t)(v >> 8); q[2] = (uint8_t)v; *p += 3; break;
        case OPK_IDX:
            while (v >= 0x80) { *q++ = (uint8_t)(v & 0x7f) | 0x80; v >>= 7; }
            *q++ = (uint8_t)v;
            *p = q;
            break;
    }
}

#endif // EMBER_OPCODE_H
