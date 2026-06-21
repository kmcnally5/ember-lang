#ifndef EMBER_VERSION_H
#define EMBER_VERSION_H

// The single source of truth for the compiler/toolchain version. Bump this ONE constant per build;
// it flows to `emberc --version`, `--help`, `--doctor` (which compares it against the installed
// binary to catch a stale editor LSP), and the language server's `serverInfo.version` (so editors
// show the right version). Format: 0.<minor>.<build> during the design phase.
#define EMBER_VERSION "0.3.40"

#endif // EMBER_VERSION_H
