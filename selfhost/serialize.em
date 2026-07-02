// selfhost/serialize.em — the self-hosted BYTECODE SERIALIZER (docs/design/bytecode-container.md, Phase 1c
// of the standalone-toolchain campaign). It turns a parsed program into a `.emb` container — the exact same
// bytes stage 0's C serializer (src/bytecode_io.c) produces — so the self-hosted compiler can emit a
// RUNNABLE artifact, not just a disassembly. It reuses codegen.em's tables + compile_fn for the bytecode
// and mirrors bytecode_write's layout; correctness is the byte-diff against stage 0 (tools/embdiff.sh).
//
// The container is LINE-precise (no columns): the codegen tracks per-node lines but not columns, which is
// exactly what lets this serializer be byte-identical to stage 0 (which now also stores lines only).

import "parser" as ps
import "codegen" as cg


// Writer accumulates the container bytes. All emission is through `mut self` METHODS (a free function with
// a `mut struct` parameter does NOT persist its mutation on the native backend — OFI-161 — but a method
// does), so the byte buffer threads correctly on both backends.
struct Writer {
    bytes: [u8]


    // emit_u8 appends one byte (the low 8 bits of v).
    fn emit_u8(mut self, v: int) {
        self.bytes.append(u8(v & 255))
    }


    // emit_bytes appends a [u8] slice verbatim.
    fn emit_bytes(mut self, data: [u8]) {
        var i = 0
        loop {
            if i >= data.len() {
                break
            }
            self.bytes.append(data[i])
            i = i + 1
        }
    }


    // emit_u32 / emit_u64 write a fixed-width little-endian integer.
    fn emit_u32(mut self, v: int) {
        var k = 0
        loop {
            if k >= 4 {
                break
            }
            self.emit_u8((v >> (8 * k)) & 255)
            k = k + 1
        }
    }


    fn emit_u64(mut self, v: int) {
        var k = 0
        loop {
            if k >= 8 {
                break
            }
            self.emit_u8((v >> (8 * k)) & 255)
            k = k + 1
        }
    }


    // emit_uvarint writes an unsigned LEB128 (7 bits per byte, high bit = continuation).
    fn emit_uvarint(mut self, v: int) {
        var vv = v
        loop {
            var b = vv & 127
            vv = vv >> 7
            if vv != 0 {
                self.emit_u8(b | 128)
            } else {
                self.emit_u8(b)
                break
            }
        }
    }


    // emit_svarint writes a zig-zag LEB128 (so small negatives like -1 stay one byte).
    fn emit_svarint(mut self, v: int) {
        self.emit_uvarint((v << 1) ^ (v >> 63))
    }


    // emit_str writes a non-NULL string as {uvarint byte-length, raw bytes}.
    fn emit_str(mut self, s: string) {
        self.emit_uvarint(s.len())
        self.emit_bytes(s.bytes())
    }


    // emit_optstr writes a NULL-able string: here always present, so length+1 then the bytes (0 = NULL).
    fn emit_optstr(mut self, s: string) {
        self.emit_uvarint(s.len() + 1)
        self.emit_bytes(s.bytes())
    }


    // emit_chunk writes one function's bytecode: verbatim code bytes, the run-length-encoded line table,
    // the int/float constant pool, and the string-literal pool — mirroring bytecode_write's per-fn block.
    fn emit_chunk(mut self, ch: cg.Chunk) {
        // Code bytes, verbatim.
        self.emit_uvarint(ch.code.len())
        var i = 0
        loop {
            if i >= ch.code.len() {
                break
            }
            self.emit_u8(ch.code[i])
            i = i + 1
        }

        // Line table, run-length-encoded: count runs (a maximal span of one line), then emit {len, line}.
        var runs = 0
        var j = 0
        loop {
            if j >= ch.code.len() {
                break
            }
            let line = ch.lines[j]
            var k = j + 1
            loop {
                if k >= ch.code.len() {
                    break
                }
                if ch.lines[k] != line {
                    break
                }
                k = k + 1
            }
            runs = runs + 1
            j = k
        }
        self.emit_uvarint(runs)
        j = 0
        loop {
            if j >= ch.code.len() {
                break
            }
            let line = ch.lines[j]
            var k = j + 1
            loop {
                if k >= ch.code.len() {
                    break
                }
                if ch.lines[k] != line {
                    break
                }
                k = k + 1
            }
            self.emit_uvarint(k - j)
            self.emit_svarint(line)
            j = k
        }

        // Constant pool (parallel arrays; const_is_float selects). int/float only.
        self.emit_uvarint(ch.const_int.len())
        var ci = 0
        loop {
            if ci >= ch.const_int.len() {
                break
            }
            if ch.const_is_float[ci] {
                self.emit_u8(1)
                self.emit_u64(0)   // TODO(float): needs a float_bits builtin to reinterpret the f64
            } else {
                self.emit_u8(0)
                self.emit_u64(ch.const_int[ci])
            }
            ci = ci + 1
        }

        // String-literal pool.
        self.emit_uvarint(ch.strings.len())
        var si = 0
        loop {
            if si >= ch.strings.len() {
                break
            }
            self.emit_str(ch.strings[si])
            si = si + 1
        }
    }


    // emit_one_struct writes a single struct entry from a DStruct's fields: name, rc/resource flags,
    // drop-fn index, then per-field {ArrayElemKind, nested-struct-id, name}. The AEK comes from the field's
    // type via codegen's array_elem_kind_from_ty (the same mapping stage 0's checker uses): a scalar packs
    // at its natural width, an aggregate / erased generic parameter is boxed. The loader repacks offsets
    // from the kinds. (rc/resource/drop_fn, nested inline value-struct fields, and bounded-generic witness
    // fields are the next increments — the compiler's own structs use none of them.)
    fn emit_one_struct(mut self, name: string, fields: [ps.Field]) {
        self.emit_str(name)
        self.emit_u8(0)             // flags: is_rc | is_resource<<1 (TODO)
        self.emit_svarint(0 - 1)    // drop_fn (TODO)
        self.emit_uvarint(fields.len())
        var fi = 0
        loop {
            if fi >= fields.len() {
                break
            }
            self.emit_uvarint(cg.array_elem_kind_from_ty(fields[fi].ty))
            self.emit_svarint(0 - 1)   // field_struct: -1 unless AEK_INLINE_STRUCT (TODO)
            self.emit_optstr(fields[fi].name)
            fi = fi + 1
        }
    }


    // emit_struct_table writes the whole struct-type table: the declared structs in DECL_STRUCT order, then
    // the monomorphized generic-struct instances (Box<Expr>, …) — each with its BASE struct's name + fields
    // (an erased generic-parameter field maps to boxed through the same kind map, matching stage 0's
    // append-model layout for a Box<Aggregate>).
    fn emit_struct_table(mut self, decls: [ps.Decl], instances: [string]) {
        var i = 0
        loop {
            if i >= decls.len() {
                break
            }
            match decls[i] {
                case DStruct(name, generics, impls, fields, methods, kind) {
                    self.emit_one_struct(name, fields)
                }
                case _ {
                }
            }
            i = i + 1
        }
        var ii = 0
        loop {
            if ii >= instances.len() {
                break
            }
            let base = base_name(instances[ii])
            var j = 0
            loop {
                if j >= decls.len() {
                    break
                }
                match decls[j] {
                    case DStruct(name, generics, impls, fields, methods, kind) {
                        if name == base {
                            self.emit_one_struct(name, fields)
                        }
                    }
                    case _ {
                    }
                }
                j = j + 1
            }
            ii = ii + 1
        }
    }
}


// base_name returns the base struct name of a monomorphized-instance key ("Box<Expr>" -> "Box").
fn base_name(key: string) -> string {
    let bs = key.bytes()
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        if int(bs[i]) == 60 {          // '<'
            return byte_slice(key, 0, i)
        }
        i = i + 1
    }
    return key
}


// variant_tag returns the tag of the variant named `name` in enum `enum_id`, or 0 if not found (the prelude
// Result::Err / Option::None failure tags).
fn variant_tag(enums: cg.EnumTable, enum_id: int, name: string) -> int {
    var vi = 0
    loop {
        if vi >= enums.v_name.len() {
            break
        }
        if enums.v_owner[vi] == enum_id && enums.v_name[vi] == name {
            return enums.v_tag[vi]
        }
        vi = vi + 1
    }
    return 0
}


// count_functions counts the function slots the container holds: every free function and struct method with
// a body, in the order emit_program (and stage 0) walks them.
fn count_functions(decls: [ps.Decl]) -> int {
    var n = 0
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        n = n + 1
                    }
                    mi = mi + 1
                }
            }
            case DFn(f) {
                if f.has_body {
                    n = n + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return n
}


// serialize_program builds the whole `.emb` container for `decls` (the merged multi-module declaration
// list) and writes it to `out_path`. `src_path` is stamped as each function's source_file (single-module
// for now). It writes the file directly rather than returning the byte array, because returning a struct
// FIELD is a partial move (unsupported); from_bytes borrows the field, so no move occurs.
fn serialize_program(decls: [ps.Decl], src_path: string, out_path: string) {
    let fn_names = cg.build_fn_names(decls)
    let structs = cg.build_structs(decls)
    let enums = cg.build_enums(decls, structs)
    let fn_rets = cg.build_fn_rets(decls, structs, enums.e_names)
    let globals = cg.build_globals(decls)
    let instances = cg.build_struct_instances(decls, structs.names)

    let func_count = count_functions(decls)
    let struct_count = structs.names.len() + instances.len()
    let variant_count = enums.v_name.len()
    let result_id = cg.cg_index_of(enums.e_names, "Result")
    let option_id = cg.cg_index_of(enums.e_names, "Option")
    // main_index defaults to 0 when there is no `main` (mirrors the checker's MonoPlan default, check.c:8477),
    // not -1 — a no-main module still serializes.
    var main_index = cg.cg_index_of(fn_names, "main")
    if main_index < 0 {
        main_index = 0
    }

    var w = Writer { bytes: [] }

    // Header.
    w.emit_u8(69)   // 'E'
    w.emit_u8(77)   // 'M'
    w.emit_u8(66)   // 'B'
    w.emit_u8(1)
    w.emit_u32(1)   // container format version
    w.emit_u32(1)   // vm ABI

    // Program header.
    w.emit_svarint(main_index)
    w.emit_svarint(result_id)
    w.emit_svarint(variant_tag(enums, result_id, "Err"))
    w.emit_svarint(option_id)
    w.emit_svarint(variant_tag(enums, option_id, "None"))
    w.emit_uvarint(func_count)
    w.emit_uvarint(struct_count)
    w.emit_uvarint(variant_count)

    // Struct-type table.
    w.emit_struct_table(decls, instances)

    // Enum-variant table.
    var vi = 0
    loop {
        if vi >= variant_count {
            break
        }
        w.emit_str(enums.v_name[vi])
        w.emit_svarint(enums.v_owner[vi])
        w.emit_svarint(enums.v_tag[vi])
        w.emit_uvarint(enums.v_arity[vi])
        vi = vi + 1
    }

    // Function table (methods interleaved with free functions, declaration order — CALL operands index it).
    var sid = 0
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        w.emit_str(name + "." + methods[mi].name)
                        w.emit_optstr(src_path)
                        w.emit_uvarint(methods[mi].params.len())
                        let ch = cg.compile_fn(methods[mi], fn_names, fn_rets, structs, enums, globals, instances, sid)
                        w.emit_chunk(ch)
                    }
                    mi = mi + 1
                }
                sid = sid + 1
            }
            case DFn(f) {
                if f.has_body {
                    w.emit_str(f.name)
                    w.emit_optstr(src_path)
                    w.emit_uvarint(f.params.len())
                    let ch = cg.compile_fn(f, fn_names, fn_rets, structs, enums, globals, instances, 0 - 1)
                    w.emit_chunk(ch)
                }
            }
            case _ {
            }
        }
        i = i + 1
    }

    write_file(out_path, from_bytes(w.bytes))
}
