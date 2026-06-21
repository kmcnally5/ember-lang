#ifndef EMBER_SEMINDEX_H
#define EMBER_SEMINDEX_H

// The semantic index — a position-keyed table the type checker fills and the
// language server queries (LSP_ROADMAP.md, Phase 2). The checker already resolves
// every identifier and infers every expression's type; without an index that
// knowledge is discarded after diagnostics. With one, the LSP answers hover,
// go-to-definition, and (later) completion / references / inlay hints from the
// SAME analysis the compiler ran — no second, divergent frontend (the
// rust-analyzer lesson). It is built only when requested (NULL = off), so batch
// compilation pays nothing.
//
// Entries are keyed by the 1-based source span of an identifier. The index owns
// its strings (copied in on add), so it outlives the checker's arena.

// The kind of symbol an entry refers to — drives the hover card's prefix
// ("(parameter)", "(function)", …), mirroring clangd's HoverInfo.Kind and
// TypeScript's "(parameter) x: T" convention.
typedef enum {
    SK_NONE = 0,
    SK_LOCAL,
    SK_PARAM,
    SK_FIELD,
    SK_METHOD,
    SK_FUNCTION,
    SK_TYPE,
    SK_VARIANT,
    SK_CONSTANT,
    SK_MODULE,
    SK_BUILTIN
} SemKind;

typedef struct {
    int     line;        // 1-based line of the identifier
    int     col;         // 1-based start column
    int     end_col;     // 1-based column just past the identifier (exclusive)
    SemKind kind;        // what this identifier denotes (drives the hover prefix)
    char   *type;        // rendered type, e.g. "int", "[string]", "Point" (owned, may be NULL)
    char   *detail;      // a one-line hover signature, e.g. "let x: int" (owned, may be NULL)
    char   *container;   // owning module alias ("ui") or type ("Point"), or NULL (owned)
    char   *doc;         // the symbol's /// doc comment, or NULL (owned)
    char   *value;       // a constant's literal value ("0xE63946"), or NULL (owned)
    int     byte_offset; // field byte offset within its struct, or -1 (n/a)
    int     byte_size;   // field/type byte size, or -1 (n/a)
    char   *def_file;    // definition's file, or NULL = same file as the reference (owned)
    int     def_line;    // definition site line, or 0 when unknown
    int     def_col;     // definition site column, or 0 when unknown
    char   *ref_file;    // file THIS occurrence is in (for cross-file references), or NULL (owned)
} SemEntry;

typedef struct {
    SemEntry *entries;
    int       count;
    int       cap;
} SemanticIndex;

// Initialise an empty index.
void semindex_init(SemanticIndex *ix);

// Record an identifier occurrence from a populated template. line/col/end_col and
// kind are taken as-is; every char* field (type/detail/container/doc/value/def_file)
// is copied in (NULL allowed), so the template's strings need not outlive the call.
// Fields not set by the caller should be zero (byte_offset/byte_size default to -1
// via the SEM_ENTRY_INIT helper below).
void semindex_add_entry(SemanticIndex *ix, const SemEntry *tmpl);

// A zero-value template with the "absent" sentinels pre-set (no layout, no def).
// Use: `SemEntry e = SEM_ENTRY_INIT;` then fill what applies.
#define SEM_ENTRY_INIT ((SemEntry){ .byte_offset = -1, .byte_size = -1 })

// Return the innermost entry whose span covers the 1-based (line, col), or NULL.
// "Innermost" = the smallest covering span, so a leaf identifier wins over any
// enclosing occurrence recorded at the same position.
const SemEntry *semindex_lookup(const SemanticIndex *ix, int line, int col);

// Free all entries and their owned strings, leaving the index empty.
void semindex_free(SemanticIndex *ix);

#endif // EMBER_SEMINDEX_H
