#ifndef EMBER_LSP_H
#define EMBER_LSP_H

// The Ember language server (LSP). Runs in-process in the compiler (`emberc --lsp`), speaking
// JSON-RPC over stdio and driving the SAME front end as a batch compile (driver.h) — one parser,
// one type checker, one source of truth. Slice 1+2: lifecycle + document sync + live diagnostics.
// Returns a process exit code. See src/lsp.c for the supported requests.
int lsp_main(void);

#endif // EMBER_LSP_H
