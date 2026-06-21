#include "chunk.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void chunk_init(Chunk *chunk) {
    chunk->code      = NULL;
    chunk->lines     = NULL;
    chunk->code_len  = 0;
    chunk->code_cap  = 0;
    chunk->consts    = NULL;
    chunk->const_len = 0;
    chunk->const_cap = 0;
    chunk->strings    = NULL;
    chunk->string_len = 0;
    chunk->string_cap = 0;
}





void chunk_free(Chunk *chunk) {
    free(chunk->code);
    free(chunk->lines);
    free(chunk->consts);
    for (size_t i = 0; i < chunk->string_len; i++) {
        free(chunk->strings[i].data);
    }
    free(chunk->strings);
    chunk_init(chunk);
}





void chunk_write(Chunk *chunk, uint8_t byte, int line) {
    if (chunk->code_len == chunk->code_cap) {
        size_t new_cap = chunk->code_cap ? chunk->code_cap * 2 : 16;
        uint8_t *grown_code = realloc(chunk->code, new_cap);
        int *grown_lines = realloc(chunk->lines, new_cap * sizeof(int));
        if (grown_code == NULL || grown_lines == NULL) {
            fprintf(stderr, "emberc: out of memory writing bytecode\n");
            exit(70);
        }
        chunk->code     = grown_code;
        chunk->lines    = grown_lines;
        chunk->code_cap = new_cap;
    }
    chunk->lines[chunk->code_len] = line;
    chunk->code[chunk->code_len]  = byte;
    chunk->code_len++;
}





size_t chunk_add_const(Chunk *chunk, Value value) {
    if (chunk->const_len == chunk->const_cap) {
        size_t new_cap = chunk->const_cap ? chunk->const_cap * 2 : 8;
        Value *grown = realloc(chunk->consts, new_cap * sizeof(Value));
        if (grown == NULL) {
            fprintf(stderr, "emberc: out of memory adding constant\n");
            exit(70);
        }
        chunk->consts    = grown;
        chunk->const_cap = new_cap;
    }
    chunk->consts[chunk->const_len] = value;
    return chunk->const_len++;
}





size_t chunk_add_string(Chunk *chunk, const char *data, size_t length) {
    if (chunk->string_len == chunk->string_cap) {
        size_t new_cap = chunk->string_cap ? chunk->string_cap * 2 : 8;
        StringConst *grown = realloc(chunk->strings, new_cap * sizeof(StringConst));
        if (grown == NULL) {
            fprintf(stderr, "emberc: out of memory adding a string\n");
            exit(70);
        }
        chunk->strings    = grown;
        chunk->string_cap = new_cap;
    }
    char *copy = malloc(length + 1);
    if (copy == NULL) {
        fprintf(stderr, "emberc: out of memory adding a string\n");
        exit(70);
    }
    memcpy(copy, data, length);
    copy[length] = '\0';
    chunk->strings[chunk->string_len].data   = copy;
    chunk->strings[chunk->string_len].length = length;
    chunk->strings[chunk->string_len].cached = NULL;   // interned on first run
    return chunk->string_len++;
}





void chunk_disassemble(const Chunk *chunk) {
    size_t offset = 0;
    int prev_line = -1;
    while (offset < chunk->code_len) {
        OpCode op = (OpCode)chunk->code[offset];
        const OperandSpec *spec = opcode_spec(op);
        int operands = opcode_operand_bytes_at(op, &chunk->code[offset + 1]);
        int line = chunk->lines ? chunk->lines[offset] : 0;

        // Show the source line, or '|' when it repeats the previous line.
        if (offset > 0 && line == prev_line) {
            printf("%04zu    |  %-8s", offset, opcode_name(op));
        } else {
            printf("%04zu %4d  %-8s", offset, line, opcode_name(op));
        }
        prev_line = line;

        // Decode each operand through the SAME codec the VM uses, so the disassembly can never
        // disagree with execution (any new opcode is handled automatically — no per-opcode branch
        // to drift). A jump offset (OPK_OFF16) shows its absolute target; a pool index for
        // OP_CONST/OP_STRING shows the constant it loads.
        const uint8_t *p = &chunk->code[offset + 1];
        for (int i = 0; spec != NULL && i < spec->count; i++) {
            OperandKind k = spec->kinds[i];
            uint32_t v = operand_read(&p, k);
            if (k == OPK_OFF16) {
                size_t base = offset + 1 + (size_t)operands;       // ip once all operands are read
                size_t target = (op == OP_LOOP) ? base - v : base + v;
                printf(" %u (-> %04zu)", v, target);
            } else {
                printf(" %u", v);
            }
        }
        if (op == OP_CONST || op == OP_STRING) {
            const uint8_t *q = &chunk->code[offset + 1];
            size_t index = operand_read(&q, OPK_IDX);
            if (op == OP_CONST && index < chunk->const_len) {
                Value cv = chunk->consts[index];
                if (IS_FLOAT(cv)) {
                    printf("  (= %g)", AS_FLOAT(cv));
                } else {
                    printf("  (= %lld)", (long long)AS_INT(cv));
                }
            } else if (op == OP_STRING && index < chunk->string_len) {
                printf("  (= \"%s\")", chunk->strings[index].data);
            }
        }
        printf("\n");
        offset += 1 + (size_t)operands;
    }
}
