#include "arena.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// One block of arena storage. The usable bytes follow the header inline via a
// flexible array member, so a block is a single allocation.
struct ArenaBlock {
    ArenaBlock   *next;
    size_t        used;
    size_t        capacity;
    unsigned char data[];
};

#define ARENA_DEFAULT_BLOCK (64 * 1024)
#define ARENA_ALIGN (_Alignof(max_align_t))

// align_up rounds n up to the next multiple of `align` (a power of two).
static size_t align_up(size_t n, size_t align) {
    return (n + align - 1) & ~(align - 1);
}





// new_block allocates a block with the given usable capacity. Failure is fatal.
static ArenaBlock *new_block(size_t capacity) {
    ArenaBlock *block = malloc(sizeof(ArenaBlock) + capacity);
    if (block == NULL) {
        fprintf(stderr, "emberc: out of memory (arena)\n");
        exit(70);
    }
    block->next     = NULL;
    block->used     = 0;
    block->capacity = capacity;
    return block;
}





void arena_init(Arena *arena, size_t block_size) {
    arena->head       = NULL;
    arena->block_size = block_size ? block_size : ARENA_DEFAULT_BLOCK;
}





void *arena_alloc(Arena *arena, size_t size) {
    size = align_up(size, ARENA_ALIGN);

    if (arena->head == NULL || arena->head->used + size > arena->head->capacity) {
        // A request larger than the standard block gets its own exact block so
        // we never refuse it; otherwise use the configured block size.
        size_t capacity = size > arena->block_size ? size : arena->block_size;
        ArenaBlock *block = new_block(capacity);
        block->next = arena->head;
        arena->head = block;
    }

    void *ptr = arena->head->data + arena->head->used;
    arena->head->used += size;
    return ptr;
}





char *arena_strndup(Arena *arena, const char *src, size_t len) {
    char *dst = arena_alloc(arena, len + 1);
    memcpy(dst, src, len);
    dst[len] = '\0';
    return dst;
}





void arena_free(Arena *arena) {
    ArenaBlock *block = arena->head;
    while (block != NULL) {
        ArenaBlock *next = block->next;
        free(block);
        block = next;
    }
    arena->head = NULL;
}
