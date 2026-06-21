# Ember reference compiler — build rules.
# `make`           builds the compiler at build/emberc (dev: -O0 -g, debuggable)
# `make test`      runs the regression suite (tests/run.sh)
# `make test-update` regenerates snapshot goldens (review the diff first!)
# `make release`   builds an optimized compiler at build/emberc-release (-O2)
# `make parallel`  builds the multicore compiler at build/emberc-par (-O2, M:N)
# `make graphics`  builds the graphics compiler at build/emberc-gfx (-O2, raylib)
# `make bench`     builds release, then runs + times every benchmarks/*.em
# `make parbench`  builds serial + parallel, runs the parallel speedup comparison
# `make clean`     removes all build artifacts

CC      := cc
# -MMD -MP make the compiler emit a .d file of header dependencies per object,
# so changing a header (e.g. opcode.h) rebuilds every object that includes it.
# Without this, stale objects can desync silently (see git history / OFI-003).
CFLAGS  := -std=c17 -Wall -Wextra -Werror -Iinclude -O0 -g -MMD -MP
BIN     := build/emberc
# The native backend's runtime library, linked into compiled Ember programs (emberc -o).
# Defined here (before `all`) so it is in `all`'s prerequisites — GNU make expands a rule's
# prerequisites when the rule is read, so a later definition would expand to empty.
RT_LIB  := build/libember_rt.a
# The PARALLEL runtime variant: the same runtime built with -DEMBER_PARALLEL=1 (atomic
# refcounts + the channel/nursery pthread machinery). `emberc -o` links this (with -lpthread)
# instead of the serial RT_LIB when the program uses spawn/nursery, so serial native binaries
# pay no threading cost. The ABI (ObjChannel size, refcount ops) must match the generated C,
# which emberc compiles with the same -DEMBER_PARALLEL for a concurrent program.
RT_LIB_PAR := build/libember_rt_par.a

# Optimized build for speed/benchmark runs. The dev build is -O0 -g for fast
# rebuilds and debuggability; this one is -O2 -DNDEBUG and so understates nothing
# when timing. Compiled in a single invocation (no per-object .o files) so its
# objects never collide with the dev build's -O0 objects in build/.
RELEASE_BIN   := build/emberc-release
RELEASE_FLAGS := -std=c17 -Wall -Wextra -Werror -Iinclude -O2 -DNDEBUG

# Multicore build. Same sources, -DEMBER_PARALLEL=1 swaps the cooperative green-
# thread scheduler for an OS-thread-per-task one (atomic refcounts, mutex/condvar
# channels, pthread nursery join) so nursery/spawn/channel programs run across all
# cores. Identical output to the serial build; only wall-clock time changes.
PARALLEL_BIN   := build/emberc-par
PARALLEL_FLAGS := -std=c17 -Wall -Wextra -Werror -Iinclude -O2 -DNDEBUG -DEMBER_PARALLEL=1

# M:N green-thread scheduler build (OFI-071): many fibers multiplexed over a worker pool, replacing
# the 1:1 pthread-per-spawn model. Layered on the EMBER_PARALLEL thread-safe heap (so both flags).
# Gated/opt-in until it clears every gate (Crucible + TSan + the mn-stress fuzzer + the suites),
# then the default `make parallel` flips to it. Build: `build/emberc-mn --emit=run <file.em>`.
MN_BIN         := build/emberc-mn
MN_FLAGS       := -std=c17 -Wall -Wextra -Werror -Iinclude -O2 -DNDEBUG -DEMBER_MN=1 -DEMBER_PARALLEL=1
# TSan over the M:N runtime — the right instrument for scheduler data races (ready-queue splices,
# channel waiter FIFOs, the live/idle/inflight accounting). -O1 keeps reports readable.
TSAN_MN_BIN    := build/emberc-tsan-mn
TSAN_MN_FLAGS  := -std=c17 -Wall -Wextra -Iinclude -O1 -g -fsanitize=thread -fno-omit-frame-pointer -DEMBER_MN=1 -DEMBER_PARALLEL=1
# ASan over M:N — use-after-free on fiber retire / per-fiber-arena merge.
ASAN_MN_BIN    := build/emberc-asan-mn
ASAN_MN_FLAGS  := -std=c17 -Wall -Wextra -Werror -Iinclude -O1 -g -fsanitize=address -fno-omit-frame-pointer -DEMBER_MN=1 -DEMBER_PARALLEL=1
# M:N + graphics (and + networking) — to dogfood the GUI apps on the M:N scheduler. Like the graphics/
# net builds, third-party headers (raylib/curl) aren't held to -Werror. The Claude app uses
# `make mn-net-graphics`; a graphics-only demo uses `make mn-graphics`.
MN_GFX_BIN     := build/emberc-mn-gfx
MN_GFX_FLAGS   := -std=c17 -Wall -Wextra -Iinclude -O2 -DNDEBUG -DEMBER_GRAPHICS=1 -DEMBER_MN=1 -DEMBER_PARALLEL=1
MN_NETGFX_BIN  := build/emberc-mn-net-gfx
MN_NETGFX_FLAGS := -std=c17 -Wall -Wextra -Iinclude -O2 -DNDEBUG -DEMBER_NET=1 -DEMBER_GRAPHICS=1 -DEMBER_MN=1 -DEMBER_PARALLEL=1

# Graphics build (MANIFESTO §5g): -DEMBER_GRAPHICS=1 links the raylib backend and
# registers the draw/window/input native primitives. raylib is found via pkg-config.
# Opt-in only — the default build above stays dependency-free and display-free, so
# `make` / `make test` never need raylib. raylib's own headers aren't held to our
# -Werror (third-party), so this build uses -Wall -Wextra without -Werror.
GRAPHICS_BIN   := build/emberc-gfx
GRAPHICS_FLAGS := -std=c17 -Wall -Wextra -Iinclude -O2 -DNDEBUG -DEMBER_GRAPHICS=1

# Networking build: -DEMBER_NET=1 links libcurl and registers the http_post FFI wrapper (HTTPS).
# Opt-in only — the default build stays dependency-free, so `make` / `make test` never need
# libcurl. libcurl's headers aren't held to our -Werror, so this build uses -Wall -Wextra only.
# (The combined net+graphics build for the desktop app is `make net-graphics`.)
NET_BIN          := build/emberc-net
NET_FLAGS        := -std=c17 -Wall -Wextra -Iinclude -O2 -DNDEBUG -DEMBER_NET=1
NETGFX_BIN       := build/emberc-net-gfx
# The desktop app also builds with -DEMBER_PARALLEL so it can run its blocking HTTPS fetch on a
# spawned worker fiber (its own OS thread) while the raylib render loop stays responsive on the
# main thread — see public/claude-desktop/gui.em (nursery + try_recv). pthread is in libc on
# macOS, so no extra link flag is needed.
NETGFX_FLAGS     := -std=c17 -Wall -Wextra -Iinclude -O2 -DNDEBUG -DEMBER_NET=1 -DEMBER_GRAPHICS=1 -DEMBER_PARALLEL=1

# AddressSanitizer builds. The older Apple clang's ASan runtime hung at startup on this macOS, so
# memory work was historically RSS-verified only; Apple clang 21 fixed that and ASan now runs. These
# instrument the VM + runtime + codegen so running a .em program flags use-after-free / double-free /
# heap-overflow with a stack trace. -O1 keeps traces readable at usable speed. NOTE: LeakSanitizer is
# unsupported on macOS, so leaks stay RSS-verified — ASan covers the temporal/spatial bugs RSS can't.
# asan-par adds -DEMBER_PARALLEL=1 to exercise the channel/nursery cross-thread paths under ASan.
ASAN_BIN       := build/emberc-asan
ASAN_FLAGS     := -std=c17 -Wall -Wextra -Werror -Iinclude -O1 -g -fsanitize=address -fno-omit-frame-pointer
ASAN_PAR_BIN   := build/emberc-asan-par
ASAN_PAR_FLAGS := -std=c17 -Wall -Wextra -Werror -Iinclude -O1 -g -fsanitize=address -fno-omit-frame-pointer -DEMBER_PARALLEL=1

SOURCES := $(wildcard src/*.c)
OBJECTS := $(patsubst src/%.c,build/%.o,$(SOURCES))
DEPS    := $(OBJECTS:.o=.d)

# Editor-asset generator (OFI-033): a build-time-only developer tool that emits the TextMate
# grammar from the single source of truth (include/vocab.def), so the grammar can't drift from
# the lexer/LSP. It is NOT part of emberc — emberc is what users/editors run; tools/ is what we
# run to maintain checked-in artifacts.
GEN_BIN := build/gen_editor_assets
GRAMMAR := editors/vscode/syntaxes/ember.tmLanguage.json

.PHONY: all test test-update test-lsp doctor help release asan asan-par asan-trace install install-vscode build-zed install-zed parallel mn tsan-mn asan-mn mn-stress mn-graphics mn-net-graphics graphics net net-graphics test-graphics test-net test-parallel crucible ceilings ledger opcheck verify string-diff bench parbench gen-editor-assets check-editor-sync clean

all: $(BIN) $(RT_LIB) $(RT_LIB_PAR)

$(BIN): $(OBJECTS)
	$(CC) $(CFLAGS) $(OBJECTS) -o $@

build/%.o: src/%.c | build
	$(CC) $(CFLAGS) -c $< -o $@

# The native backend's runtime, packaged as a static library that compiled Ember
# programs (`emberc -o`) link against. Built from src/runtime.c + src/cextern.c — both
# self-contained (no front-end, no VM dispatch), so a generated binary pulls in only the
# object runtime (allocation, refcount, drop, struct/marshalling) and the C FFI registry
# (em_ffi → cextern_call). -O2 for runtime speed; objects are named distinctly so they
# never collide with the dev build's build/*.o. The compiler links these via $(SOURCES).
# (RT_LIB is defined near the top so `all` can depend on it.)
RT_FLAGS := -std=c17 -Wall -Wextra -Werror -Iinclude -O2 -DNDEBUG
$(RT_LIB): src/runtime.c src/cextern.c include/ember_rt.h include/value.h include/program.h include/cextern.h | build
	$(CC) $(RT_FLAGS) -c src/runtime.c -o build/runtime_rt.o
	$(CC) $(RT_FLAGS) -c src/cextern.c -o build/cextern_rt.o
	ar rcs $@ build/runtime_rt.o build/cextern_rt.o

# The parallel runtime variant (same source, -DEMBER_PARALLEL=1): atomic refcounts + the
# channel/nursery/worker threading. Linked by `emberc -o` (with -lpthread) for concurrent
# programs only. Built distinctly so it never collides with the serial runtime object.
$(RT_LIB_PAR): src/runtime.c src/cextern.c include/ember_rt.h include/value.h include/program.h include/cextern.h | build
	$(CC) $(RT_FLAGS) -DEMBER_PARALLEL=1 -c src/runtime.c -o build/runtime_rt_par.o
	$(CC) $(RT_FLAGS) -DEMBER_PARALLEL=1 -c src/cextern.c -o build/cextern_rt_par.o
	ar rcs $@ build/runtime_rt_par.o build/cextern_rt_par.o

build:
	mkdir -p build

# Pull in the generated header-dependency rules (silent if absent on first run).
-include $(DEPS)

test: all check-editor-sync
	@tests/run.sh
	@tests/run-doctor.sh

# Build the editor-asset generator. Depends on vocab.def so adding a word reflows the grammar.
$(GEN_BIN): tools/gen_editor_assets.c include/vocab.def | build
	$(CC) $(CFLAGS) tools/gen_editor_assets.c -o $@

# Regenerate the TextMate grammar in place from include/vocab.def.
gen-editor-assets: $(GEN_BIN)
	@$(GEN_BIN) > $(GRAMMAR)
	@echo "regenerated $(GRAMMAR)"

# Drift gate (run by `make test`): fail if the committed grammar is stale w.r.t. vocab.def.
check-editor-sync: $(GEN_BIN)
	@$(GEN_BIN) | diff -u $(GRAMMAR) - \
	  || { echo "ERROR: $(GRAMMAR) is stale — run 'make gen-editor-assets' (OFI-033)."; exit 1; }

test-update: all
	@tests/run.sh --update

# Language-server regression (JSON-RPC over stdio; uses a Python test driver, so it's kept out of
# the dependency-free `make test`). Builds the compiler first.
test-lsp: all
	@tests/run-lsp.sh

# Optimized compiler. Recompiles all sources (the project is small and release
# builds are infrequent), so it always reflects the current source.
release: | build
	$(CC) $(RELEASE_FLAGS) $(SOURCES) -o $(RELEASE_BIN)

# AddressSanitizer compilers (see ASAN_FLAGS). Run the suite under one with:
#   make asan && ASAN_OPTIONS=detect_leaks=0 build/emberc-asan --emit=run <file.em>
# Single invocation like release so the instrumented objects never collide with the dev build's.
asan: | build
	$(CC) $(ASAN_FLAGS) $(SOURCES) -o $(ASAN_BIN)

asan-par: | build
	$(CC) $(ASAN_PAR_FLAGS) $(SOURCES) -o $(ASAN_PAR_BIN)

# The "memory tape": ASan + the reclaim double-drop detector (-DEMBER_DROP_TRACE). The pool hides a
# use-after-free from plain ASan (it recycles, not free()s), so the detector stamps a sentinel after
# each reclaim and aborts with both drop sites if an object is reclaimed twice. This caught OFI-058.
# Run: ASAN_OPTIONS=detect_leaks=0 build/emberc-trace --emit=run <file.em>
asan-trace: | build
	$(CC) $(ASAN_FLAGS) -DEMBER_DROP_TRACE=1 $(SOURCES) -o build/emberc-trace

# Install a release build to a central, self-contained toolchain dir (default ~/.ember) so editors
# and tools find it from ANY folder: the binary lands at $(PREFIX)/bin/emberc and the stdlib at
# $(PREFIX)/std, which the binary resolves relative to itself (<bin>/../std). The VS Code client
# launches $(PREFIX)/bin/emberc --lsp. Re-run after changes: `make install`.
PREFIX ?= $(HOME)/.ember
install: release
	mkdir -p "$(PREFIX)/bin" "$(PREFIX)/std"
	# rm-then-cp, NOT cp-in-place: overwriting the existing binary keeps its inode, and macOS
	# caches the ad-hoc code signature (cdhash) per-inode. The new content's cdhash then mismatches
	# the cache and the kernel SIGKILLs the process on exec ("Killed: 9") — the launched LSP dies
	# silently and editors show no hover/diagnostics. Removing first gives the copy a fresh inode.
	rm -f "$(PREFIX)/bin/emberc"
	cp $(RELEASE_BIN) "$(PREFIX)/bin/emberc"
	cp std/*.em "$(PREFIX)/std/"
	@echo "installed emberc + std to $(PREFIX)  (VS Code: emberLsp.serverPath = $(PREFIX)/bin/emberc)"

# Deploy the VS Code extension. The CANONICAL SOURCE is editors/vscode/ in this repo.
# IMPORTANT: modern VS Code (1.74+) does NOT scan ~/.vscode/extensions on startup — it
# only loads extensions listed in ~/.vscode/extensions/extensions.json, which is written
# by a proper install. Hand-copying a folder there is silently ignored (the old method;
# it cost us a debugging session). So we PACKAGE a .vsix from editors/vscode and install
# it via the `code` CLI, which registers it correctly and GLOBALLY (lights up any .em
# file system-wide). node_modules (vscode-languageclient, bundled into the vsix) is
# fetched with npm only when absent so re-packs are offline + fast. Re-run after editing
# the grammar or glue: `make install-vscode`, then reload the VS Code window.
CODE_CLI ?= $(shell command -v code || echo "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
install-vscode:
	@if [ ! -d editors/vscode/node_modules ]; then \
		echo "fetching vscode-languageclient (one-time)…"; \
		cd editors/vscode && npm install --omit=dev; \
	fi
	cd editors/vscode && npx --yes @vscode/vsce package --allow-missing-repository -o /tmp/ember-lang.vsix
	"$(CODE_CLI)" --install-extension /tmp/ember-lang.vsix --force
	@echo "installed VS Code extension via $(CODE_CLI)  (reload the VS Code window to pick it up)"

# Build the Zed extension (Rust → WebAssembly). The CANONICAL SOURCE is editors/zed/. Needs Rust via
# rustup (NOT Homebrew — Zed drives `rustup target add wasm32-wasip1` itself) and the wasm target;
# `. ~/.cargo/env` puts cargo on PATH even though make runs /bin/sh, not the login shell. This only
# sanity-builds the wasm module — Zed itself recompiles the wasm AND the tree-sitter grammar at
# install time. See editors/zed/README.md.
WASM_TARGET ?= wasm32-wasip1
build-zed:
	. "$$HOME/.cargo/env" 2>/dev/null; cd editors/zed && cargo build --release --target $(WASM_TARGET)
	@echo "built editors/zed wasm ($(WASM_TARGET))"

# Zed dev extensions install from the GUI, not a CLI: command palette → `zed: install dev extension`
# → select editors/zed/. We build the wasm first so any Rust error surfaces here, then point the way.
install-zed: build-zed
	@echo "in Zed: command palette → 'zed: install dev extension' → select $(CURDIR)/editors/zed/"

# `make doctor`: the setup health-check. Runs `emberc --doctor` (binary / stdlib / frontend / LSP)
# and additionally checks the Rust+wasm toolchain the Zed extension build needs — the trap newcomers
# hit (Homebrew's `rust` has no rustup, so the wasm target can't be added). Sources ~/.cargo/env so
# a rustup install is found even though make runs /bin/sh, not the login shell.
doctor: all
	@build/emberc --doctor
	@printf '\nZed extension toolchain (only needed to BUILD the Zed extension):\n'
	@. "$$HOME/.cargo/env" 2>/dev/null; \
	 if command -v rustup >/dev/null 2>&1 && rustup target list --installed 2>/dev/null | grep -q wasm32-wasip1; then \
	   echo "  [ok]   rustup + wasm32-wasip1 target present"; \
	 elif command -v rustup >/dev/null 2>&1; then \
	   echo "  [!!]   rustup present but the wasm32-wasip1 target is missing"; \
	   echo "         fix: rustup target add wasm32-wasip1"; \
	 elif command -v cargo >/dev/null 2>&1; then \
	   echo "  [!!]   cargo found but NOT rustup — Homebrew 'rust' cannot build Zed extensions"; \
	   echo "         fix: brew uninstall rust; then install rustup from https://sh.rustup.rs"; \
	 else \
	   echo "  [--]   no Rust toolchain (only needed for the Zed extension; see https://rustup.rs)"; \
	 fi
	@printf '\nZed grammar freshness (the tree-sitter grammar is pinned by commit in extension.toml):\n'
	@if [ -d editors/zed/tree-sitter-ember/.git ]; then \
	   head=$$(git -C editors/zed/tree-sitter-ember rev-parse HEAD 2>/dev/null); \
	   pinned=$$(grep -E '^rev *= *"' editors/zed/extension.toml | sed -E 's/.*"([0-9a-fA-F]+)".*/\1/'); \
	   if [ "$$head" = "$$pinned" ]; then \
	     echo "  [ok]   extension.toml rev matches tree-sitter-ember HEAD"; \
	   else \
	     echo "  [!!]   STALE grammar: extension.toml pins $$pinned but HEAD is $$head"; \
	     echo "         (edited grammar.js? regenerate + commit, then update rev in editors/zed/extension.toml)"; \
	   fi; \
	 else echo "  [--]   editors/zed/tree-sitter-ember is not a git repo (grammar not pinned yet)"; fi

# `make help`: every build/test/install command in one place — the canonical list so none get lost.
help:
	@echo "Ember build commands — make <target>:"
	@echo ""
	@echo "  Build & run"
	@echo "    make                  build the dev compiler (build/emberc)"
	@echo "    make release          optimized build         make parallel   multicore build (1:1)"
	@echo "    make mn               M:N green-thread scheduler build (OFI-071; gated/experimental)"
	@echo "    make mn-net-graphics  M:N + networking + raylib (run the Flare Claude app on M:N)"
	@echo "    make graphics | net-graphics | mn-graphics   raylib (+net / +M:N) builds"
	@echo "  Test & verify"
	@echo "    make mn-stress        M:N scheduler stress/scaling fuzzer (+ make tsan-mn / asan-mn)"
	@echo "    make test             golden suite + doctor regression"
	@echo "    make test-lsp         language-server regression"
	@echo "    make verify           full gate (asan + crucible + ceilings + ledger + opcheck)"
	@echo "    make crucible | ceilings | ledger | opcheck   targeted fuzzers/gates"
	@echo "    make asan             AddressSanitizer build"
	@echo "    make doctor           setup health-check (binary, stdlib, frontend, install, Zed toolchain)"
	@echo "  Install & editors"
	@echo "    make install          install emberc + std to ~/.ember  (editors run THIS binary)"
	@echo "    make install-vscode   build + install the VS Code extension"
	@echo "    make build-zed        build the Zed extension wasm"
	@echo "    make install-zed      build + show the Zed dev-extension install step"
	@echo "  Graphics & net (opt-in, default build stays dependency-free)"
	@echo "    make graphics         graphics build (raylib)    make net / net-graphics  (libcurl)"
	@echo ""
	@echo "Using the language? Run 'emberc --help'."

# Multicore compiler (see PARALLEL_FLAGS). Single invocation like `release`, so it
# always reflects current source and never collides with the dev -O0 objects.
parallel: | build
	$(CC) $(PARALLEL_FLAGS) $(SOURCES) -o $(PARALLEL_BIN)

# M:N scheduler compiler (see MN_FLAGS). Single invocation like `parallel`.
mn: | build
	$(CC) $(MN_FLAGS) $(SOURCES) -o $(MN_BIN)

# TSan / ASan over the M:N runtime (scheduler race + use-after-free gates).
tsan-mn: | build
	$(CC) $(TSAN_MN_FLAGS) $(SOURCES) -o $(TSAN_MN_BIN)

asan-mn: | build
	$(CC) $(ASAN_MN_FLAGS) $(SOURCES) -o $(ASAN_MN_BIN)

# M:N scheduler + graphics (and + networking) compilers — run the GUI apps on M:N. Single invocation
# like `graphics`/`net-graphics`. Run: build/emberc-mn-net-gfx --emit=run <app.em>
mn-graphics: | build
	$(CC) $(MN_GFX_FLAGS) `pkg-config --cflags raylib freetype2` $(SOURCES) `pkg-config --libs raylib freetype2` -o $(MN_GFX_BIN)

mn-net-graphics: | build
	$(CC) $(MN_NETGFX_FLAGS) `curl-config --cflags` `pkg-config --cflags raylib freetype2` $(SOURCES) `curl-config --libs` `pkg-config --libs raylib freetype2` -o $(MN_NETGFX_BIN)

# Graphics compiler (see GRAPHICS_FLAGS). Links raylib + FreeType (hinted text) via pkg-config;
# single invocation like release. Run a demo with: build/emberc-gfx --emit=run <file.em>
graphics: | build
	$(CC) $(GRAPHICS_FLAGS) `pkg-config --cflags raylib freetype2` $(SOURCES) `pkg-config --libs raylib freetype2` -o $(GRAPHICS_BIN)

# Networking compiler (see NET_FLAGS): links libcurl via curl-config, registers the http_post
# FFI wrapper. Run an HTTPS program with: build/emberc-net --emit=run <file.em>
net: | build
	$(CC) $(NET_FLAGS) `curl-config --cflags` $(SOURCES) `curl-config --libs` -o $(NET_BIN)

# Combined networking + graphics compiler — the desktop app (public/) needs both: HTTPS for
# the Anthropic API and raylib for the GUI. Run with: build/emberc-net-gfx --emit=run <file.em>
net-graphics: | build
	$(CC) $(NETGFX_FLAGS) `curl-config --cflags` `pkg-config --cflags raylib freetype2` $(SOURCES) `curl-config --libs` `pkg-config --libs raylib freetype2` -o $(NETGFX_BIN)

# Graphics/UI regression suite (needs the raylib build + a display, so it's separate
# from the dependency-free `make test`). Builds the graphics compiler first.
test-graphics: graphics
	@tests/run-graphics.sh

# Networking regression suite (std/http + the reusable Anthropic client). Needs the libcurl build,
# so it's separate from the dependency-free `make test`; the cases make no live request. Builds the
# networking compiler first.
test-net: net
	@tests/run-net.sh

# Crucible — the memory-ownership fuzzer (tools/crucible.{c,sh}). Generates danger-zone programs
# (value-structs through erased generics/aggregates, field mutation, interpolation, loops) and runs
# each through five oracles — the double-drop detector, ASan, an RSS leak check, and the VM↔native
# differential — deduping and shrinking each finding to a minimal repro. Fails on a NEW finding (one
# not baselined in tools/crucible-known.txt). Override the seed count: `tools/crucible.sh <N>`.
crucible:
	@tools/crucible.sh

# Ceilings — the compiler-LIMITS stress tester (tools/ceilings.sh). Crucible's sibling for the OTHER
# recurring class: a bytecode operand or pool/table index too NARROW to hold a value past 255, which
# silently wraps and miscompiles (OFI-007 / OFI-047 / OFI-056). Pushes each dimension (constants,
# strings, locals, functions, struct types, fields, variants) past the 256 boundary and asserts the
# only safe outcomes — WORKS (compiles, runs, VM == native) or CAPPED (clean error) — never a wrap.
# Fails on drift from tools/ceilings-known.txt. Override the size: `tools/ceilings.sh <N>`.
ceilings:
	@tools/ceilings.sh

# Opcheck — the bytecode operand-layer consistency gate (tools/opcheck.{c,sh}). The operand layout of
# each opcode lives in ONE place (the spec in include/opcode.h) and a shared codec (operand_read/
# operand_write) drives the encoder, decoder, and disassembler — so they can't drift (the class
# behind OFI-007/047/056, a narrow operand wrapping or a handler reading the wrong width). This
# proves it: (1) the codec round-trips for every opcode/kind; (2) a -DEMBER_OPCHECK VM build asserts,
# over the whole corpus, that each handler consumes EXACTLY the operand bytes its spec declares.
opcheck:
	@tools/opcheck.sh

# Ledger — the resource-LINEARITY fuzzer (tools/ledger.{c,sh}). The third sibling: Crucible fuzzes
# runtime memory ownership, Ceilings fuzzes narrow operands, Ledger fuzzes the compile-time MUST-CONSUME
# analysis for a linear `Ptr` FFI handle (OFI-049) — the AND-merge `consumed` dataflow dual to the
# affine `moved`. It generates Ptr-lifetime programs (if/else+match trees, close-on-break read loops,
# reassignment chains) each with a KNOWN accept/reject oracle and asserts the compiler's verdict
# matches — catching BOTH a leak that compiles (unsound) and a balanced program rejected (over-strict).
ledger:
	@tools/ledger.sh

# mn-stress — the M:N green-thread scheduler stress/scaling fuzzer (tools/mn-stress.sh). Generates
# danger-zone concurrent programs with KNOWN deterministic answers (checksums, not output ordering)
# and runs each under a WATCHDOG: a hang, wrong answer, or wrong exit code fails. Headline case spawns
# THOUSANDS of fibers in one nursery — a count the 1:1 pthread-per-spawn build can't create as threads.
# The gate (with `make tsan-mn` + the serial==mn differential) that must pass before the default flips.
mn-stress: mn
	@tools/mn-stress.sh

# Verify — the one-command gate runner (tools/verify.sh): build + test + opcheck + ceilings + crucible
# with a consolidated PASS/FAIL summary. The single check to run after any compiler change.
# `make verify` runs all; `tools/verify.sh fast` skips the slow fuzzer; `tools/verify.sh test opcheck`
# runs a subset.
verify:
	@tools/verify.sh

# String differential oracle (tools/string-diff.py): fuzzes random multi-byte UTF-8 strings + indices
# through std/string's code-point helpers and diffs the results against CPython's native (ground-truth)
# Unicode semantics. The proof that std/string is UTF-8 correct. Uses python3 (a dev-tool dep, like the
# LSP driver), so it is kept OUT of the dependency-free `make test`/`make verify`. `make string-diff`
# runs the default fuzz; `tools/string-diff.py <N> <seed>` controls depth/reproducibility.
string-diff: all
	@python3 tools/string-diff.py

# Parallel-runtime correctness suite: programs that are only correct under -DEMBER_PARALLEL
# (spawn-at-spawn-time concurrency — a spawned task runs alongside the nursery body). Kept out
# of the serial `make test` because they would block forever under the cooperative scheduler.
# Builds the parallel compiler first; each case runs under a timeout (see tests/run-parallel.sh).
test-parallel: parallel
	@tests/run-parallel.sh

# Parallel speedup comparison: same nursery/spawn/channel suite run under the serial
# and parallel compilers, tabulated by section (see benchmarks/parbench.sh).
parbench: release parallel
	@benchmarks/parbench.sh

# Run and time every benchmark with the optimized build. Results and wall-clock
# time are both shown so correctness and speed are visible together.
bench: release
	@echo "== benchmarks (optimized -O2 build) =="
	@for f in benchmarks/*.em; do \
		echo ""; echo "--- $$f ---"; \
		time $(RELEASE_BIN) --emit=run $$f; \
	done

clean:
	rm -rf build
