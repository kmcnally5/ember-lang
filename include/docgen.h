#ifndef EMBER_DOCGEN_H
#define EMBER_DOCGEN_H

#include <stdio.h>
#include "ast.h"

// docgen_emit writes Markdown API documentation for `prog` to `out`: one section
// per top-level declaration, rendering each one's signature and the author's
// `///` doc comment (cleaned by the parser — the same prose the LSP shows on
// hover). This is the third consumer of the doc-comment corpus
// (source -> LSP + docs): a comment written once becomes both the editor hover
// card and the reference page, so the two cannot drift. `title` heads the page.
void docgen_emit(const Program *prog, const char *title, FILE *out);

#endif // EMBER_DOCGEN_H
