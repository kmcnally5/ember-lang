#include "semindex.h"

#include <stdlib.h>
#include <string.h>

// The semantic index container (see semindex.h). A flat, append-only array of
// span-keyed entries with a linear "innermost covering span" lookup. The index is
// small (one entry per identifier occurrence in one file) and short-lived (rebuilt
// per request), so a plain array beats anything cleverer; if profiling ever says
// otherwise, sort by (line, col) and binary-search.




// dup0 copies a NUL-terminated string, returning NULL for a NULL input.
static char *dup0(const char *s) {
    if (s == NULL) {
        return NULL;
    }
    size_t n = strlen(s);
    char  *out = malloc(n + 1);
    if (out != NULL) {
        memcpy(out, s, n + 1);
    }
    return out;
}




void semindex_init(SemanticIndex *ix) {
    ix->entries = NULL;
    ix->count   = 0;
    ix->cap     = 0;
}




void semindex_add_entry(SemanticIndex *ix, const SemEntry *tmpl) {
    if (ix->count == ix->cap) {
        ix->cap = ix->cap ? ix->cap * 2 : 64;
        ix->entries = realloc(ix->entries, (size_t)ix->cap * sizeof(SemEntry));
    }
    SemEntry *e = &ix->entries[ix->count++];
    *e = *tmpl;                       // scalars (line/col/kind/offsets/def_line/…)
    e->type      = dup0(tmpl->type);  // then own every string independently
    e->detail    = dup0(tmpl->detail);
    e->container = dup0(tmpl->container);
    e->doc       = dup0(tmpl->doc);
    e->value     = dup0(tmpl->value);
    e->def_file  = dup0(tmpl->def_file);
    e->ref_file  = dup0(tmpl->ref_file);
}




const SemEntry *semindex_lookup(const SemanticIndex *ix, int line, int col) {
    const SemEntry *best = NULL;
    for (int i = 0; i < ix->count; i++) {
        const SemEntry *e = &ix->entries[i];
        if (e->line != line || col < e->col || col >= e->end_col) {
            continue;
        }
        // Prefer the tightest span covering the cursor (the leaf identifier).
        if (best == NULL || (e->end_col - e->col) < (best->end_col - best->col)) {
            best = e;
        }
    }
    return best;
}




void semindex_free(SemanticIndex *ix) {
    for (int i = 0; i < ix->count; i++) {
        free(ix->entries[i].type);
        free(ix->entries[i].detail);
        free(ix->entries[i].container);
        free(ix->entries[i].doc);
        free(ix->entries[i].value);
        free(ix->entries[i].def_file);
        free(ix->entries[i].ref_file);
    }
    free(ix->entries);
    ix->entries = NULL;
    ix->count   = 0;
    ix->cap     = 0;
}
