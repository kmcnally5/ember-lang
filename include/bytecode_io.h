#ifndef EMBER_BYTECODE_IO_H
#define EMBER_BYTECODE_IO_H

#include "program.h"

// The `.emb` bytecode container (docs/design/bytecode-container.md): a serialized CompiledProgram — the
// exact artifact the VM executes — so a compiler can emit a RUNNABLE program, not just a disassembly.
// This is the Phase 1 step that lets the self-hosted bytecode backend produce something executable; for
// now stage 0 both writes (`--emit=bytecode-bin`) and loads/runs (`--run-bytecode`) it, which also gives
// the self-hosted serializer a stage-0 oracle to diff against.
//
// bytecode_write serializes a compiled program to `path`. bytecode_read loads one back into a fresh
// CompiledProgram, allocating owned storage that compiled_program_free can release and RECOMPUTING each
// struct's packed field offsets from the serialized field kinds (mirroring the checker's build_layouts,
// so a loaded layout is byte-identical to a compiled one — the container carries kinds, not offsets).
// Both return 0 on success, non-zero on any I/O, allocation, or malformed-container error.
//
// The byte stream bakes in opcode numbers, native-builtin ids, and ArrayElemKind values, so a container
// is only valid for a matching VM ABI. The header pins EMBER_BYTECODE_ABI and bytecode_read rejects a
// mismatch loudly. Bump the ABI whenever those enumerations change (the surface `make opcheck` guards).
#define EMBER_BYTECODE_ABI 1u

int bytecode_write(const CompiledProgram *prog, const char *path);
int bytecode_read(const char *path, CompiledProgram *out);

#endif // EMBER_BYTECODE_IO_H
