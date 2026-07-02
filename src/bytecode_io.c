#include "bytecode_io.h"

#include "chunk.h"
#include "value.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// The `.emb` container format is specified in docs/design/bytecode-container.md. In brief: a fixed header
// (magic "EMB\x01", format version, VM ABI), a program header (entry index + prelude Result/Option ids),
// then the struct-type table (field KINDS, not byte offsets — the loader repacks), the enum-variant table,
// and the function table (per-function chunk: verbatim code bytes, run-length-encoded line/col, an int/float
// constant pool, and a string-literal pool). Little-endian throughout; small non-negative integers use
// unsigned LEB128 (uvarint), signed/`-1`-bearing fields use zig-zag LEB128 (svarint).

// ===================================================================================================
//  Write side — a growable byte buffer
// ===================================================================================================

typedef struct {
    uint8_t *data;
    size_t   len;
    size_t   cap;
    int      oom;   // sticky: once allocation fails, every further append is a no-op and write() bails
} ByteBuf;

static void bb_reserve(ByteBuf *b, size_t extra) {
    if (b->oom || b->len + extra <= b->cap) {
        return;
    }
    size_t cap = b->cap ? b->cap : 256;
    while (cap < b->len + extra) {
        cap *= 2;
    }
    uint8_t *grown = realloc(b->data, cap);
    if (grown == NULL) {
        b->oom = 1;
        return;
    }
    b->data = grown;
    b->cap  = cap;
}

static void bb_u8(ByteBuf *b, uint8_t v) {
    bb_reserve(b, 1);
    if (!b->oom) {
        b->data[b->len++] = v;
    }
}

static void bb_bytes(ByteBuf *b, const void *src, size_t n) {
    bb_reserve(b, n);
    if (!b->oom && n > 0) {
        memcpy(b->data + b->len, src, n);
        b->len += n;
    }
}

static void bb_u32(ByteBuf *b, uint32_t v) {
    for (int i = 0; i < 4; i++) {
        bb_u8(b, (uint8_t)((v >> (8 * i)) & 0xFF));
    }
}

static void bb_u64(ByteBuf *b, uint64_t v) {
    for (int i = 0; i < 8; i++) {
        bb_u8(b, (uint8_t)((v >> (8 * i)) & 0xFF));
    }
}

static void bb_uvarint(ByteBuf *b, uint64_t v) {
    do {
        uint8_t byte = (uint8_t)(v & 0x7F);
        v >>= 7;
        if (v != 0) {
            byte |= 0x80;
        }
        bb_u8(b, byte);
    } while (v != 0);
}

static void bb_svarint(ByteBuf *b, int64_t v) {
    bb_uvarint(b, ((uint64_t)v << 1) ^ (uint64_t)(v >> 63));   // zig-zag
}

// A non-NULL C-string name: uvarint length + raw bytes (no NUL stored).
static void bb_str(ByteBuf *b, const char *s) {
    size_t n = s ? strlen(s) : 0;
    bb_uvarint(b, (uint64_t)n);
    bb_bytes(b, s, n);
}

// A NULL-able C-string (a hidden witness field name is NULL): 0 = NULL, else length+1 then the bytes, so
// an empty non-NULL string and a NULL are distinct.
static void bb_optstr(ByteBuf *b, const char *s) {
    if (s == NULL) {
        bb_uvarint(b, 0);
        return;
    }
    size_t n = strlen(s);
    bb_uvarint(b, (uint64_t)n + 1);
    bb_bytes(b, s, n);
}

// A length-explicit byte blob (a string CONSTANT may contain embedded NULs, so its length is authoritative
// — do not use strlen): uvarint length + raw bytes.
static void bb_data(ByteBuf *b, const char *data, size_t length) {
    bb_uvarint(b, (uint64_t)length);
    bb_bytes(b, data, length);
}

int bytecode_write(const CompiledProgram *prog, const char *path) {
    ByteBuf b = { NULL, 0, 0, 0 };

    // Header.
    bb_u8(&b, 'E');
    bb_u8(&b, 'M');
    bb_u8(&b, 'B');
    bb_u8(&b, 0x01);
    bb_u32(&b, 1u);                 // container format version
    bb_u32(&b, EMBER_BYTECODE_ABI); // VM ABI the baked-in opcode/native/AEK ids belong to

    // Program header.
    bb_svarint(&b, prog->main_index);
    bb_svarint(&b, prog->result_enum_id);
    bb_svarint(&b, prog->err_tag);
    bb_svarint(&b, prog->option_enum_id);
    bb_svarint(&b, prog->none_tag);
    bb_uvarint(&b, (uint64_t)prog->count);
    bb_uvarint(&b, (uint64_t)prog->struct_count);
    bb_uvarint(&b, (uint64_t)prog->variant_count);

    // Struct-type table: per field we store the KIND + nested-inline id + name; the loader recomputes
    // offset[]/total_size (so this stays valid for an Ember serializer that has kinds but not offsets).
    for (int s = 0; s < prog->struct_count; s++) {
        const StructType *st = &prog->structs[s];
        bb_str(&b, st->name);
        bb_u8(&b, (uint8_t)((st->is_rc ? 1 : 0) | (st->is_resource ? 2 : 0)));
        bb_svarint(&b, st->drop_fn);
        bb_uvarint(&b, (uint64_t)st->field_count);
        for (int f = 0; f < st->field_count; f++) {
            bb_uvarint(&b, (uint64_t)st->kind[f]);
            bb_svarint(&b, st->field_struct ? st->field_struct[f] : -1);
            bb_optstr(&b, st->field_names ? st->field_names[f] : NULL);
        }
    }

    // Enum-variant table (names for Fault value rendering).
    for (int v = 0; v < prog->variant_count; v++) {
        const EnumVariantInfo *ev = &prog->variants[v];
        bb_str(&b, ev->name);
        bb_svarint(&b, ev->enum_id);
        bb_svarint(&b, ev->variant_index);
        bb_uvarint(&b, (uint64_t)ev->field_count);
    }

    // Function table (declaration order — CALL operands index it, so the order is load-bearing).
    for (int fi = 0; fi < prog->count; fi++) {
        const Function *fn = &prog->functions[fi];
        const Chunk    *ch = &fn->chunk;
        bb_str(&b, fn->name);
        bb_optstr(&b, fn->source_file);
        bb_uvarint(&b, (uint64_t)fn->arity);

        // Code bytes, verbatim (the operand codec is intrinsic to the stream — never re-encoded).
        bb_uvarint(&b, (uint64_t)ch->code_len);
        bb_bytes(&b, ch->code, ch->code_len);

        // Line/col table, run-length-encoded (a whole instruction shares one position). Count runs, then
        // emit each as {run length, line, col}.
        size_t run_count = 0;
        for (size_t i = 0; i < ch->code_len; ) {
            int line = ch->lines ? ch->lines[i] : 0;
            int col  = ch->cols  ? ch->cols[i]  : 0;
            size_t j = i + 1;
            while (j < ch->code_len && (ch->lines ? ch->lines[j] : 0) == line &&
                   (ch->cols ? ch->cols[j] : 0) == col) {
                j++;
            }
            run_count++;
            i = j;
        }
        bb_uvarint(&b, (uint64_t)run_count);
        for (size_t i = 0; i < ch->code_len; ) {
            int line = ch->lines ? ch->lines[i] : 0;
            int col  = ch->cols  ? ch->cols[i]  : 0;
            size_t j = i + 1;
            while (j < ch->code_len && (ch->lines ? ch->lines[j] : 0) == line &&
                   (ch->cols ? ch->cols[j] : 0) == col) {
                j++;
            }
            bb_uvarint(&b, (uint64_t)(j - i));
            bb_svarint(&b, line);
            bb_svarint(&b, col);
            i = j;
        }

        // Constant pool: int/float only (codegen never pools an object). Tag byte + 8 LE bytes.
        bb_uvarint(&b, (uint64_t)ch->const_len);
        for (size_t ci = 0; ci < ch->const_len; ci++) {
            Value cv = ch->consts[ci];
            if (IS_FLOAT(cv)) {
                uint64_t bits;
                double   d = AS_FLOAT(cv);
                memcpy(&bits, &d, sizeof bits);
                bb_u8(&b, 1);
                bb_u64(&b, bits);
            } else {
                bb_u8(&b, 0);
                bb_u64(&b, (uint64_t)AS_INT(cv));
            }
        }

        // String-literal pool (exact bytes; may contain embedded NULs).
        bb_uvarint(&b, (uint64_t)ch->string_len);
        for (size_t si = 0; si < ch->string_len; si++) {
            bb_data(&b, ch->strings[si].data, ch->strings[si].length);
        }
    }

    if (b.oom) {
        free(b.data);
        return 1;
    }

    FILE *f = fopen(path, "wb");
    if (f == NULL) {
        free(b.data);
        return 1;
    }
    size_t wrote = (b.len > 0) ? fwrite(b.data, 1, b.len, f) : 0;
    int    ok    = (wrote == b.len);
    fclose(f);
    free(b.data);
    return ok ? 0 : 1;
}

// ===================================================================================================
//  Read side — a bounds-checked cursor over the file bytes
// ===================================================================================================

typedef struct {
    const uint8_t *p;
    const uint8_t *end;
    int            error;   // sticky: set on any short read / malformed varint
} Reader;

static uint8_t rd_u8(Reader *r) {
    if (r->p >= r->end) {
        r->error = 1;
        return 0;
    }
    return *r->p++;
}

// Returns a pointer to `n` bytes and advances past them, or sets error (and returns NULL) if short.
static const uint8_t *rd_take(Reader *r, size_t n) {
    if ((size_t)(r->end - r->p) < n) {
        r->error = 1;
        return NULL;
    }
    const uint8_t *q = r->p;
    r->p += n;
    return q;
}

static uint32_t rd_u32(Reader *r) {
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) {
        v |= (uint32_t)rd_u8(r) << (8 * i);
    }
    return v;
}

static uint64_t rd_u64(Reader *r) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) {
        v |= (uint64_t)rd_u8(r) << (8 * i);
    }
    return v;
}

static uint64_t rd_uvarint(Reader *r) {
    uint64_t v = 0;
    int      shift = 0;
    for (;;) {
        uint8_t byte = rd_u8(r);
        if (r->error) {
            return 0;
        }
        v |= (uint64_t)(byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) {
            break;
        }
        shift += 7;
        if (shift >= 64) {   // malformed: a varint longer than 64 bits
            r->error = 1;
            return 0;
        }
    }
    return v;
}

static int64_t rd_svarint(Reader *r) {
    uint64_t zz = rd_uvarint(r);
    return (int64_t)(zz >> 1) ^ -(int64_t)(zz & 1);   // un-zig-zag
}

// Reads a uvarint length + bytes into a fresh malloc'd NUL-terminated C string (owned by the caller).
static char *rd_str_dup(Reader *r) {
    uint64_t n = rd_uvarint(r);
    if (r->error) {
        return NULL;
    }
    const uint8_t *q = rd_take(r, (size_t)n);
    if (r->error) {
        return NULL;
    }
    char *s = malloc((size_t)n + 1);
    if (s == NULL) {
        r->error = 1;
        return NULL;
    }
    if (n > 0) {
        memcpy(s, q, (size_t)n);
    }
    s[n] = '\0';
    return s;
}

// The NULL-able counterpart of rd_str_dup (0 = NULL, else length+1 then bytes).
static char *rd_optstr_dup(Reader *r) {
    uint64_t v = rd_uvarint(r);
    if (r->error || v == 0) {
        return NULL;
    }
    uint64_t       n = v - 1;
    const uint8_t *q = rd_take(r, (size_t)n);
    if (r->error) {
        return NULL;
    }
    char *s = malloc((size_t)n + 1);
    if (s == NULL) {
        r->error = 1;
        return NULL;
    }
    if (n > 0) {
        memcpy(s, q, (size_t)n);
    }
    s[n] = '\0';
    return s;
}

// aek_width / struct_packed_size recompute a struct's packed field offsets from field kinds — a faithful
// mirror of check.c's field_storage_size (a scalar packs at its natural width; a nested inline struct
// packs its own fields recursively; everything else is a 16-byte boxed Value). structs[] must already be
// fully loaded (all kinds present) before this runs. A struct can never inline-contain itself (that would
// be infinite size, which the checker rejects), so the mutual recursion terminates.
static int aek_width(const StructType *structs, int struct_count, int kind, int field_struct);

static int struct_packed_size(const StructType *structs, int struct_count, int sid) {
    if (sid < 0 || sid >= struct_count) {
        return 16;   // defensive: an out-of-range nested id falls back to a boxed slot
    }
    const StructType *st = &structs[sid];
    int total = 0;
    for (int f = 0; f < st->field_count; f++) {
        total += aek_width(structs, struct_count, st->kind[f],
                           st->field_struct ? st->field_struct[f] : -1);
    }
    return total;
}

static int aek_width(const StructType *structs, int struct_count, int kind, int field_struct) {
    switch (kind) {
        case AEK_I8:  case AEK_U8:  case AEK_BOOL: return 1;
        case AEK_I16: case AEK_U16:               return 2;
        case AEK_I32: case AEK_U32: case AEK_F32: return 4;
        case AEK_I64: case AEK_U64: case AEK_F64: return 8;
        case AEK_INLINE_STRUCT:
            return struct_packed_size(structs, struct_count, field_struct);
        default:
            return 16;   // AEK_BOXED
    }
}

int bytecode_read(const char *path, CompiledProgram *out) {
    compiled_program_init(out);

    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) {
        fclose(f);
        return 1;
    }
    uint8_t *data = malloc((size_t)sz > 0 ? (size_t)sz : 1);
    if (data == NULL) {
        fclose(f);
        return 1;
    }
    size_t got = (sz > 0) ? fread(data, 1, (size_t)sz, f) : 0;
    fclose(f);
    if (got != (size_t)sz) {
        free(data);
        return 1;
    }

    Reader r = { data, data + sz, 0 };

    // Header + ABI check.
    uint8_t m0 = rd_u8(&r), m1 = rd_u8(&r), m2 = rd_u8(&r), m3 = rd_u8(&r);
    uint32_t fmt = rd_u32(&r);
    uint32_t abi = rd_u32(&r);
    if (r.error || m0 != 'E' || m1 != 'M' || m2 != 'B' || m3 != 0x01 ||
        fmt != 1u || abi != EMBER_BYTECODE_ABI) {
        free(data);
        return 1;
    }

    // Program header.
    out->main_index     = (int)rd_svarint(&r);
    out->result_enum_id = (int)rd_svarint(&r);
    out->err_tag        = (int)rd_svarint(&r);
    out->option_enum_id = (int)rd_svarint(&r);
    out->none_tag       = (int)rd_svarint(&r);
    uint64_t func_count    = rd_uvarint(&r);
    uint64_t struct_count  = rd_uvarint(&r);
    uint64_t variant_count = rd_uvarint(&r);
    if (r.error) {
        free(data);
        compiled_program_free(out);
        return 1;
    }

    // Allocate the three tables zero-filled and record their counts UP FRONT, so a mid-read failure
    // leaves compiled_program_free walking well-formed (NULL / chunk_init) entries.
    if (func_count > 0) {
        out->functions = calloc((size_t)func_count, sizeof(Function));
    }
    out->count = (int)func_count;
    if (struct_count > 0) {
        out->structs = calloc((size_t)struct_count, sizeof(StructType));
    }
    out->struct_count = (int)struct_count;
    if (variant_count > 0) {
        out->variants = calloc((size_t)variant_count, sizeof(EnumVariantInfo));
    }
    out->variant_count = (int)variant_count;
    if ((func_count > 0 && out->functions == NULL) || (struct_count > 0 && out->structs == NULL) ||
        (variant_count > 0 && out->variants == NULL)) {
        free(data);
        compiled_program_free(out);
        return 1;
    }

    // Struct-type table (metadata only; offsets computed in a second pass below).
    for (uint64_t s = 0; s < struct_count && !r.error; s++) {
        StructType *st = &out->structs[s];
        st->name        = rd_str_dup(&r);
        uint8_t flags   = rd_u8(&r);
        st->is_rc       = (flags & 1) ? 1 : 0;
        st->is_resource = (flags & 2) ? 1 : 0;
        st->drop_fn     = (int)rd_svarint(&r);
        uint64_t fc     = rd_uvarint(&r);
        if (r.error) {
            break;
        }
        st->field_count = (int)fc;
        size_t n = (fc > 0) ? (size_t)fc : 1;
        st->kind         = malloc(sizeof(int) * n);
        st->field_struct = malloc(sizeof(int) * n);
        st->offset       = malloc(sizeof(int) * n);   // filled by the offset pass
        st->field_names  = calloc(n, sizeof(char *));
        if (st->kind == NULL || st->field_struct == NULL || st->offset == NULL ||
            st->field_names == NULL) {
            r.error = 1;
            break;
        }
        for (uint64_t fld = 0; fld < fc && !r.error; fld++) {
            st->kind[fld]         = (int)rd_uvarint(&r);
            st->field_struct[fld] = (int)rd_svarint(&r);
            st->field_names[fld]  = rd_optstr_dup(&r);
        }
    }

    // Offset pass: now that every struct's kinds are loaded, pack offsets exactly as the checker did.
    for (int s = 0; s < out->struct_count && !r.error; s++) {
        StructType *st  = &out->structs[s];
        int         off = 0;
        for (int f = 0; f < st->field_count; f++) {
            st->offset[f] = off;
            off += aek_width(out->structs, out->struct_count, st->kind[f],
                             st->field_struct ? st->field_struct[f] : -1);
        }
        st->total_size = off;
    }

    // Enum-variant table.
    for (uint64_t v = 0; v < variant_count && !r.error; v++) {
        EnumVariantInfo *ev = &out->variants[v];
        ev->name          = rd_str_dup(&r);
        ev->enum_id       = (int)rd_svarint(&r);
        ev->variant_index = (int)rd_svarint(&r);
        ev->field_count   = (int)rd_uvarint(&r);
    }

    // Function table.
    for (uint64_t fi = 0; fi < func_count && !r.error; fi++) {
        Function *fn = &out->functions[fi];
        chunk_init(&fn->chunk);
        fn->name        = rd_str_dup(&r);
        fn->source_file = rd_optstr_dup(&r);
        fn->arity       = (int)rd_uvarint(&r);
        fn->checkable   = 0;   // the --check fuzz metadata is not persisted (not needed to run)

        uint64_t code_len = rd_uvarint(&r);
        if (r.error) {
            break;
        }
        const uint8_t *code = rd_take(&r, (size_t)code_len);
        if (r.error) {
            break;
        }

        // Expand the line/col RLE, writing each code byte with its position via chunk_write (which grows
        // code/lines/cols in sync and owns the copy — `code` points into the file buffer freed below).
        uint64_t run_count = rd_uvarint(&r);
        size_t   idx       = 0;
        for (uint64_t run = 0; run < run_count && !r.error; run++) {
            uint64_t run_len = rd_uvarint(&r);
            int      line    = (int)rd_svarint(&r);
            int      col     = (int)rd_svarint(&r);
            for (uint64_t k = 0; k < run_len && idx < code_len; k++) {
                chunk_write(&fn->chunk, code[idx], line, col);
                idx++;
            }
        }
        if (r.error) {
            break;
        }
        if (idx != code_len) {   // the RLE runs did not cover every code byte — malformed
            r.error = 1;
            break;
        }

        uint64_t const_count = rd_uvarint(&r);
        for (uint64_t ci = 0; ci < const_count && !r.error; ci++) {
            uint8_t  tag  = rd_u8(&r);
            uint64_t bits = rd_u64(&r);
            if (r.error) {
                break;
            }
            if (tag == 1) {
                double d;
                memcpy(&d, &bits, sizeof d);
                chunk_add_const(&fn->chunk, FLOAT_VAL(d));
            } else {
                chunk_add_const(&fn->chunk, INT_VAL((int64_t)bits));
            }
        }

        uint64_t string_count = rd_uvarint(&r);
        for (uint64_t si = 0; si < string_count && !r.error; si++) {
            uint64_t       slen  = rd_uvarint(&r);
            const uint8_t *sdata = rd_take(&r, (size_t)slen);
            if (r.error) {
                break;
            }
            chunk_add_string(&fn->chunk, (const char *)sdata, (size_t)slen);
        }
    }

    free(data);
    if (r.error) {
        compiled_program_free(out);
        return 1;
    }
    return 0;
}
