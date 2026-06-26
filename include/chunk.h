#ifndef EMBER_CHUNK_H
#define EMBER_CHUNK_H

#include "opcode.h"
#include "value.h"
#include <stddef.h>
#include <stdint.h>

// A Chunk is one compiled unit: a flat byte stream of instructions plus a pool
// of constants those instructions reference by index. It is the artifact codegen
// produces and the VM consumes.
// A string literal's decoded bytes, owned by the chunk. OP_STRING references one
// by index; the VM materialises an ObjString from it at run time — once. Strings
// are immutable and `==` compares contents, so every execution of the same literal
// can share one interned object: `cached` is filled lazily by the first execution
// (with a chunk-held reference so it survives the whole run) and later executions
// just bump its refcount instead of allocating a copy.
typedef struct {
    char      *data;
    size_t     length;
    ObjString *cached;   // lazily interned runtime object, or NULL
} StringConst;

typedef struct {
    uint8_t     *code;
    int         *lines;    // source line for each code byte (parallel to `code`)
    int         *cols;     // source column for each code byte (parallel to `code`) — OFI-111a
    size_t       code_len;
    size_t       code_cap;
    Value       *consts;
    size_t       const_len;
    size_t       const_cap;
    StringConst *strings;
    size_t       string_len;
    size_t       string_cap;
} Chunk;

void chunk_init(Chunk *chunk);
void chunk_free(Chunk *chunk);

// Appends one byte (an opcode or operand) to the code stream, recording the
// source `line`/`col` it was lowered from. This source-position table is the
// foundation for the execution tape, Fault locations (OFI-111a), and any future
// debugger (MANIFESTO §5d).
void chunk_write(Chunk *chunk, uint8_t byte, int line, int col);

// Adds a constant to the pool and returns its index for OP_CONST.
size_t chunk_add_const(Chunk *chunk, Value value);

// Copies `length` bytes into the chunk's string pool and returns the index for
// OP_STRING. The chunk owns the copy.
size_t chunk_add_string(Chunk *chunk, const char *data, size_t length);

// Prints a human-readable disassembly of the chunk to stdout, one instruction
// per line. Used by the `--emit=bytecode` driver mode and codegen golden tests.
void chunk_disassemble(const Chunk *chunk);

#endif // EMBER_CHUNK_H
