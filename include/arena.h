#ifndef EMBER_ARENA_H
#define EMBER_ARENA_H

#include <stddef.h>

// A region (arena) allocator: memory is bump-allocated from large blocks and
// never freed individually — the whole arena is released at once with
// arena_free. This suits a batch compiler, where every AST node for one parse
// shares a lifetime, and it keeps node allocation to a pointer bump instead of
// a malloc per node. Allocations are aligned for any scalar type.
typedef struct ArenaBlock ArenaBlock;

typedef struct {
    ArenaBlock *head;        // most-recent block; allocation cursor lives here
    size_t      block_size;  // size of each fresh block (large requests get their own)
} Arena;

// Initialises an arena. A block_size of 0 selects a sensible default.
void arena_init(Arena *arena, size_t block_size);

// Returns `size` bytes of zero-uninitialised, suitably aligned storage owned by
// the arena. Never returns NULL: allocation failure is fatal (a compiler that
// cannot allocate cannot proceed).
void *arena_alloc(Arena *arena, size_t size);

// Copies `len` bytes from `src` into the arena and NUL-terminates the copy,
// returning the new string. Used to give AST nodes owned copies of identifiers
// and literal text that outlive the token buffer.
char *arena_strndup(Arena *arena, const char *src, size_t len);

// Releases every block. The arena is reusable after this (as if freshly
// initialised with the same block_size).
void arena_free(Arena *arena);

#endif // EMBER_ARENA_H
