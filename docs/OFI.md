---
title: OFI Log
nav_exclude: true
sitemap: false
description: "Opportunities For Improvement — bugs, design flaws, and improvements tracked while building Ember."
layout: default
---

# Ember — OFI Log

*Opportunities For Improvement.* Bugs, design flaws, and inconsistencies with the
[manifesto](MANIFESTO.md) found while building Ember. Raise here instead of coding around them.

Each item gets a stable `OFI-NNN` id. Move resolved items to **Closed** with a one-line
resolution; never reuse or renumber ids.

---

## Open

**Status (2026-06-23): nothing on the critical path.** The compiler + stdlib are sound — the language-correctness sweeps (OFI-062..064 erased-generic double-frees, 083 slice overflow, 095 `_`-discard, 100..105 external review) all landed regression-tested + adversarially reviewed, and the unified **Fault** error-artifact campaign (OFI-106..111) is in (compile-diagnostic render + native parity are the tracked remainders). Recent work has centred on **Flare**, the declarative UI layer: visual polish, deluxe docking + persistence (OFI-112..119), then a **60fps performance + animation/notifications campaign** (OFI-126..133) — a `measure_text` cache, immediate-mode list virtualization, a real-time spring timestep, idle-CPU event-gating, and the presence/fade/toast/undo stack — all dogfooded in the Claude desktop app.

**The open set is all deliberate-deferral or low-priority**, in four buckets: **(1) language widening for the systems claim** — real numeric widths (OFI-123) and a `Ptr` that can OWN a C resource / RAII handle (**OFI-122, the priority**); **(2) native-backend (AST→C) parity** — VM-only Faults (OFI-109); **(3) M:N scaling** — work-stealing deques (OFI-087) and right-sized fiber stacks for the 100k-fiber tier (OFI-088), both measure-first; **(4) Flare polish** — atomic-widget stretch (OFI-115) and a single-giant-turn reparse residual (OFI-121, largely answered by virtualization OFI-129). The remainder is cosmetic (`_`-discard LSP follow-ups OFI-097/098) or long-deferred perf (OFI-050 linear symbol scan, OFI-018 deferred frees).

The table below is the **index — newest first; status (OPEN / CLOSED / PARTIAL) is in the Disposition column.** Substantial items get a full `### OFI-NNN` write-up: open ones under this section, resolved ones under **Closed**.

| OFI | Item | Disposition |
|-----|------|-------------|
| OFI-142 | raylib — the hidden graphics backend — is **not packaged in Debian or Ubuntu** (any component; `apt-cache search raylib` returns only the unrelated `python3-xraylib`). So the Linux flagship (graphics / the Flare desktop app) cannot be provisioned from the system package manager the way it is from Homebrew on macOS, or `pacman`/`dnf` on Arch/Fedora. The build itself is fully portable — raylib 5.5 built from source → `make net-graphics` links clean on Ubuntu 24.04 (a 909 KB binary) — so this is purely a dependency-provisioning gap, not a code-portability one. | **CLOSED 2026-06-24** (found while landing the Linux port, OFI-141; surfaced for real by Karl on Ubuntu — the full build fell back to plain). Root cause was two-fold: raylib is unpackaged on Debian/Ubuntu AND the installer asked for it in a SINGLE atomic `apt-get install` alongside freetype/curl, so the unfindable `libraylib-dev` aborted the whole command and left even freetype/curl uninstalled. Fixed in `docs/install.sh`: freetype/curl/pkg-config install on their OWN package-manager call; raylib is tried as a distro package (Arch/Fedora/openSUSE carry it) and otherwise built from source by the new `ensure_raylib_from_source` (installs cmake+GL/X11 via apt/dnf/pacman/zypper/apk, clones raylib `$EMBER_RAYLIB_VERSION`, CMake build+install, `ldconfig`, then exports `PKG_CONFIG_PATH` for the build). Validated end-to-end on Ubuntu 24.04 x86_64: raylib 5.5.0 built from source -> `Graphics + networking dependencies OK` -> full `net-graphics` compiler installed, no plain fallback. CI already builds raylib from source too. Networking-only (`make net`, libcurl) needs none of this. |
| OFI-141 | The compiler **built and ran on macOS only** — not from any language or Apple-framework dependency (the core is clean POSIX C17: no `__APPLE__`, `mach/*`, frameworks, or arch assumptions) but from a cluster of build-time macOS-isms invisible under Apple clang/libc: **(1)** `-std=c17` on glibc hides the POSIX functions used (`realpath`/`popen`/`strdup`/`random`/`clock_gettime`/`sysconf(_SC_NPROCESSORS_ONLN)`) — strict ISO C with no `_DEFAULT_SOURCE`; **(2)** libm is a separate library on Linux (folded into libc on macOS), so every math builtin (`sqrt`/`pow`/`sin`/…) was an undefined reference at link without `-lm`; **(3)** the parallel/threaded builds relied on pthread living in libc (true on macOS) and passed no `-pthread`; **(4)** gcc `-Werror` flagged two issues clang silently passed — a `char cn[24]` that **truncated a generated C identifier** (cgen_c.c — a latent miscompile) and an `at[MAX_PARAMS]` `-O2` maybe-uninitialized; **(5)** the `tools/*.sh` gate scripts (opcheck/crucible) carried their own un-ported `cc` lines; **(6)** crucible's ASan oracle tripped because gcc enables LeakSanitizer by default on Linux (off on macOS) and its RSS oracle used BSD `/usr/bin/time -l`. | **CLOSED 2026-06-24** — root-caused and fixed against real Linux (Docker `gcc:13`/glibc 2.36 + Ubuntu 24.04, x86_64), not by reasoning: `-D_DEFAULT_SOURCE` + `-lm` + `-pthread` threaded through every Makefile flag group and the native `emberc -o` link; the two gcc-found bugs fixed at root (buffer sized to the cname field; arrays zero-initialised); the tools scripts ported; crucible's ASan oracle set to `detect_leaks=0` for macOS parity and `rss_of` made cross-platform (`time -v`). Result: dev + release + parallel + native all build, **regression 384/0**, **all 7 verify gates green** (opcheck/ceilings/ledger/crucible) on x86_64 Linux; macOS host re-verified unbroken. Installer de-gated for Linux (apt/dnf/pacman/zypper/apk); GitHub Actions CI added (Linux + macOS — the project's first CI). Full write-up below. Graphics provisioning tracked separately as OFI-142. |
| OFI-140 | Enum payload fields are declared with a **required name** (`enum Shape { Circle(radius: float) }` — an unnamed `Circle(float)` is rejected: `error: expected ':' after field name`), yet variants are **constructed positionally** (`Circle(2.0)`) and the declared name cannot be used at the construction site (`Circle(radius: 2.0)` → `error: expected ')' after arguments`). Structs are the mirror image: the same `name: type` declaration syntax, but constructed **by name** with braces (`Rect { w: 10.0, h: 5.0 }`). So an enum-payload name is mandatory to declare but inert everywhere it could be used — `match` binds to arbitrary names, not the declared one — making it pure documentation. A model reaches for `Circle(radius: 2.0)` by analogy to struct literals and is rejected. | **OPEN** (surface-syntax inconsistency; found 2026-06-24 alongside OFI-139, while building the [for-llms](/for-llms) cheat-sheet). Resolve for least surprise one of two ways: (a) accept named construction for enum payloads too, mirroring struct literals (the model's instinct, and consistent with how the field is already written); or (b) make the declaration name optional (`Circle(float)`) so the required-but-inert name disappears. (a) is the more consistent. Low priority — no correctness impact. |
| OFI-139 | String interpolation renders only a number, a string, or a bool — a struct or interface value is rejected: `"{shape}"` → `error: an interpolation '{ }' accepts a number, a string, or a bool`. Models (and people) reach for value interpolation by habit — Python f-strings, Rust `{}`/`{:?}`, Go `%v` — so this is the single most common first-write error a zero-/few-shot LLM makes in Ember (caught in a qwen-coder-30B-generated program: it wrote `println("Processing {shape} ...")` over a `Drawable`). It cuts against the [manifesto](https://github.com/kmcnally5/ember-lang/blob/main/MANIFESTO.md)'s LLM-first / "least surprise to the model" stance — the model's default assumption is that any value is interpolatable. | **OPEN** (LLM-first ergonomics; found 2026-06-24). Two paths: (a) cheap — make the error actionable ("interpolate a field or a method that yields a number, string, or bool"); (b) the real fix — a derivable `Show`/`Display`-style rendering (or an auto-debug format) so `"{shape}"` works, which is what models expect. Documented as a workaround in the [for-llms](/for-llms) cheat-sheet meanwhile. Decision needed: does Ember want implicit value stringification at all (explicitness vs least-surprise)? |
| OFI-138 | The Flare Claude app SEGFAULTED on close under the **M:N runtime** (`run-flare-mn.sh` → `emberc-mn-net-gfx`): `draw.close()`'s raylib/OpenGL teardown (`UnloadFont` → `glDeleteTextures`) ran on an M:N WORKER thread, not the GL-context thread (worker 0). Root cause: the M:N scheduler's single shared ready-queue (`rq_pop`, vm.c) lets a parked-then-requeued fiber resume on ANY worker thread. The main fiber runs the render loop on worker 0 without yielding (so loop GL calls stay on T0), but the **nursery join at shutdown PARKS it**, and it resumes on a different worker → GL teardown off-context → SEGV (READ at the zero page in `glDeleteTextures`, ASan-traced through `scheduler_worker_main` vm.c:1704 on thread T4). The 1:1 PARALLEL build (`run-flare.sh`) pins the main fiber to its thread, so it never reproduced there; my second (Ollama) worker likely tipped the scheduling but the bug is latent in the runtime. | **APP-FIXED 2026-06-23** (`flare_chat.em`: `draw.close()` + `tape_off()` moved BEFORE the nursery join, so GL teardown runs on worker 0 while the main fiber is still pinned there — verified clean under MN+ASan for no-send AND after-request close). **RUNTIME FIX STILL OPEN:** the M:N scheduler should PIN the main/GL fiber to worker 0 (a worker-0-only ready slot the other workers never service), so ANY graphics/Cocoa-on-M:N program is sound, not just this app. Needed before M:N can host GUI work as the default. |
| OFI-137 | A COLD local model gives no specific feedback during load: the first Ollama send after launch (or after the keep-alive unloads the model) makes Ollama spend ~10–15s loading the 12B weights into the GPU BEFORE the first SSE token, during which the app shows only the generic animated "Claude is thinking" spinner. Root-caused Karl's "GPU heats then cools after ~40s, nothing output" — the path is functionally CORRECT (verified end-to-end: a cold-start trace showed `pend=true str=false dN=0` for ~15s, then 231 deltas flowed and the reply committed; a warm 723-token reply streamed + displayed + saved cleanly), but a user watching the GPU work with no tokens reasonably reads the silent wait as a hang. | **OPEN** (UX polish, low effort; found 2026-06-23 while debugging the Ollama MVP). While `pending && provider==Ollama && no deltas yet`, show a distinct "Loading <model>…" hint instead of the generic spinner (or surface first-token latency). Turns a confusing silent wait into a clear state. |
| OFI-136 | Local-model discovery (`oll.list_models` → `GET /api/tags`) runs SYNCHRONOUSLY on the render thread — at launch (when the saved provider is Ollama), on a provider switch, and on "Refresh models". For a local daemon this is sub-millisecond (or an instant connection-refused when it's down, via the 4 s connect timeout), so the UI never visibly stalls today. A future REMOTE OpenAI-compatible endpoint behind the same picker would, however, block the frame for the round-trip. | **OPEN** (low priority; correct for the Ollama-only MVP shipped 2026-06-23). When remote providers land, move discovery onto a one-shot worker fiber (the streaming workers already prove the pattern) and show a brief "discovering…" state. |
| OFI-135 | The Claude desktop app's agentic tools (`read_file`/`write_file`) are advertised only on the **Anthropic** path — they ride Anthropic's `tool_use`/`tool_result` content-block format. The new **Ollama (local)** provider sends no `tools`, so the agentic loop never triggers and a local model runs as plain chat even when it reports a `tools` capability (e.g. `mistral-nemo`). Ollama's OpenAI-compatible tool shape (`tools[].function` + `tool_calls` deltas + `role:"tool"` messages) is different and `ollama.build_request`/`stream_worker` don't yet emit/parse it. | **OPEN** (deliberate MVP deferral; Ollama-only first pass shipped 2026-06-23). When the provider layer widens to OpenAI/OpenRouter/etc., add OpenAI-format tool mapping behind the existing `send_turn` seam, gated on the model's advertised `capabilities` (many local models can't do tools). |
| OFI-134 | The public `curl -fsSL https://ember-lang.org/install.sh \| sh` installer aborted at `sh: line 210: EMBER_PREFIX?: unbound variable` even though `$EMBER_PREFIX` is set unconditionally on line 26. Root cause: under a UTF-8 locale (reporter's `LANG=C.UTF-8`), bash 3.2 (macOS `/bin/sh`) mis-parses a `$VAR` IMMEDIATELY followed by a multibyte char — `info "Installing to $EMBER_PREFIX…"` let the first byte of the Unicode ellipsis `…` (`E2 80 A6`) be read INTO the variable name, so it looked up an unset `EMBER_PREFIX‹E2›` and tripped `set -u` (the stray byte renders as `?`). Only line 210 had `$VAR…` adjacency; every other ellipsis followed a `)` (`source (main)…`, `take a minute)…`), which terminates the name — so those printed fine, exactly matching the reporter's console output. The installer carried 11 non-ASCII chars (5 `—`, 6 `…`) purely for typography. | **CLOSED 2026-06-23** (reported by Karl; root-caused on his machine by reproducing the exact `curl\|sh` under `LC_ALL=C.UTF-8` with `$EMBER_PREFIX` SET → `EMBER_PREFIX�: unbound variable`, while plain `C`/`POSIX` and the file-fed `/bin/sh install.sh` path both printed clean). Made `docs/install.sh` pure ASCII (`—`→`-`, `…`→`...`): `grep -P '[^\x00-\x7F]'` now empty, `sh -n` clean, and a full piped install under `C.UTF-8` to a temp prefix succeeds end-to-end. A `curl\|sh` installer must be locale-independent ASCII. NOTE: ember-lang.org serves the COMMITTED copy, so the live fix needs a commit + push. |
| OFI-133 | Toasts had no INTERACTIVE affordance — a notification could not carry an action (the reversible-"Undo" pattern), so a destructive action like deleting a conversation was instant and unrecoverable. | **CLOSED 2026-06-23.** `f.toast_action(text, label, token)` renders an accent action button on the pill; a RELEASE over it fires `token` for one frame via `f.take_action()` and dismisses the toast (manual release-edge hit-test against the direct-drawn pill). Dogfooded as Undo-delete: deleting a conversation snapshots it (title+turns, `.clone()`d — Ember's linearity REFUSED the move-out of a field/loop-var, catching a real aliasing bug at compile time) and shows "Conversation deleted · [Undo]"; the token re-inserts + re-selects it. Regression `flare_toast_action.em` (press ≠ fire; release fires + dismisses); the no-action pill stayed byte-identical (graphics 43/0). |
| OFI-132 | Flare had no transient-notification primitive — action feedback ("Copied", errors, confirmations) had nowhere to surface. | **CLOSED 2026-06-23** (committed `bb3073f`). `f.toast(text)` enqueues; `f.toast_layer()` (called once per frame after `finish()`) draws + ages the queue as a fade+slide pill stack on the modal layer, auto-dismissing on a deterministic frame timer (~3.3s), built on `presence()`. Keeps the loop awake while a toast is alive so the timer advances under idle event-waiting (OFI-126). Dogfooded: code-block + message Copy → "Copied to clipboard". Regression `flare_toast.em`. |
| OFI-131 | Flare had no opacity/compositing — a subtree could not fade as one, blocking a proper enter/exit (slide-only) plus dimming / disabled / scrim states; text was always fully opaque. | **CLOSED 2026-06-23** (committed `bb3073f`). A fade multiplier (`set_alpha` builtin) captured per draw command and folded into final alpha at flush (one capture site, no per-op cost); `f.fade_begin(amount)/fade_end()` is a nesting paint bracket. No-op at the default — text/rect emit a tape `alpha` field only when <255, so every un-faded golden is byte-identical. Dogfooded: the message enter is now fade+slide. Regression `flare_fade.em`. |
| OFI-130 | Flare elements SNAPPED in and out — additions popped, deletions teleported; no enter/exit motion (the biggest animation gap left after OFI-093's springs + FLIP). | **CLOSED 2026-06-23** (committed `bb3073f`). `f.presence(key, present) -> float` springs 0→1 on first sight (enter) and 1→0 when `present` flips false (exit, after which the caller drops the element), on the keyed-state surface so it survives list reorders; pairs with `at`/`fade` for fade+slide. Dogfooded on the chat composer/messages. Regression `flare_presence.em`. |
| OFI-129 | Flare rebuilt + re-laid-out the ENTIRE transcript every frame (O(total)), so a long chat dropped below 60fps — OFI-120's cull skipped DRAWING off-screen rows but still BUILT and laid them out. "A single screen's worth is cheap" (forrestthewoods) was broken for unbounded content. | **CLOSED 2026-06-23** — the standing answer to OFI-121. Immediate-mode list virtualization (Dear ImGui `ListClipper`, adapted): `f.virtual_begin(key,count)` / `virtual_item(i)` / `virtual_end()` build ONLY the rows whose extent falls in the scroll viewport + overscan; spacer struts of the skipped rows' summed height keep scroll-height + sticky-follow exact; per-row heights are LEARNED from last frame's solved rows (estimated until first seen — react-window's variable-height model). O(total) → O(visible): proven flat at ~1.5 ms/frame for 40 AND 400 turns. The app transcript virtualizes over visual BLOCKS (a tool_use folds its result into one item, so the window never aliases mid-pair). Regression `flare_virtual.em`. Research-grounded (pretext, react-window, ImGui). |
| OFI-128 | Spring/FLIP animation advanced a FIXED `SPRING_DT` once per FRAME, not per wall-second — so on heavy frames (a redock dropping to ~20fps) animations played in SLOW MOTION; a ~0.5s glide stretched to seconds. Karl: "redock… looks great but takes way too long." | **CLOSED 2026-06-23.** `frame_steps()` builtin returns how many fixed 1/60s sub-steps the last frame's wall-time spanned (clamped 1..10); `_spring`/`_flip_axis` sub-step that many times → real-time catch-up regardless of fps. Opt-in via `f.set_realtime(true)` (the app enables it) so the DEFAULT stays the deterministic fixed timestep the golden suite depends on — all goldens byte-identical (the headless suite runs at steps==1). |
| OFI-127 | `measure_text` (raylib `MeasureTextEx`, which walks every glyph) was UNCACHED, so every label/button/wrapped word was re-shaped through FreeType every frame in the LAYOUT pass, then AGAIN in paint — 2× FreeType per text run per frame, the dominant active-frame CPU cost (the root multiplier behind word-wrap, `rich_text`, ellipsis fitting, button sizing). | **CLOSED 2026-06-23.** A direct-mapped 16384-slot cache keyed by (text, font slot, size) in `graphics.c` (evict-on-collision; flushed on a DPI/backing-scale change). Pure memoisation → byte-identical widths, all goldens unchanged. Warm frames do ZERO FreeType measuring (111 calls → 0 freetype, 100% hit on stable content); only changed strings miss while typing/streaming. `measure_misses()` builtin + the `EMBER_MEASURE_STATS` instrument (per-frame ms-work + hit-rate). Regression `flare_measure_cache.em`. |
| OFI-126 | A static Flare app burned ~99% of a CPU core — the immediate-mode loop re-ran build+layout+paint 60×/sec even when nothing changed (raylib `SetTargetFPS(60)` only caps the rate; each interpreted frame saturated the core). Karl: "CPU sits at 99% when the app is idle?" | **CLOSED 2026-06-23.** Adaptive idle gating on raylib 5.5 `EnableEventWaiting`/`DisableEventWaiting` (`set_event_waiting` builtin): the loop free-runs while there is input, an animation in flight (`f.is_animating()`), or a reply streaming (+ a short coast), otherwise `EndDrawing` blocks on the OS event queue — idle CPU ~99% → ~0%. `had_input()` builtin reports mouse move/wheel/resize PLUS a held-key sweep of the raw key queue so OS auto-repeat doesn't stutter (fixed a "backspace deletes in bursts of three" bug). Verified live (Activity Monitor) + `flare_idle.em`. |
| OFI-123 | The value model is width-erased: numeric widths are semantic-only (range/overflow/display take the operand's width) but every scalar occupies the same runtime slot. A `u64` LITERAL is writable only to 2⁶³−1 (parser parses via signed range; larger reached by arithmetic/conversion); only packed scalar ARRAYS store at width (`[u8]`=1 B/elem) while a scalar `u8` local takes a full slot. | OPEN (deliberate deferral, large). The "real widths" piece behind the systems-language claim; no correctness risk — range/overflow already enforced on operations. Relates to native-layout umbrella OFI-051. |
| OFI-122 | A `Ptr` may not be stored in a struct/array/enum/channel or used as a generic arg (the OFI-049 erasure-proof type-formation ban), so no value can OWN a C resource — no `struct File { handle: Ptr }`, no `Option<Ptr>` checked-open, no connection-pool/wrapper type. Every C handle lives as a bare local, closed on every path. The sharpest limit for "real C bindings". | OPEN (priority). Lift via typed handles with a user-declared `Drop`/close (the "typed-handles-with-Drop" future in docs/design/ptr-linearity.md R1). Relations: OFI-099, OFI-043. |
| OFI-121 | Flare re-parses + rebuilds the ENTIRE node tree every frame: `f.markdown` calls `md.parse(text)` and re-emits every rich-text run on each pass, and `finish()` re-solves the whole layout — all O(content) per frame regardless of what's visible. After OFI-120's viewport cull removed the per-frame PAINT cost, this build/layout cost is the remaining O(n) for a large static message (e.g. a 3000-line reply that's just sitting there, being scrolled). The immediate-mode idiom rebuilds every frame by design, but a large unchanging transcript pays a parse+layout tax 60×/sec for no change. | **LARGELY RESOLVED 2026-06-23 by OFI-129** (immediate-mode virtualization): the transcript now builds + lays out only the VISIBLE turns, so a long multi-turn chat is O(visible) not O(total) — the per-frame parse/layout tax is gone for the scrolled-transcript case that filed this. **RESIDUAL (OPEN, narrow):** a SINGLE turn taller than the viewport is one virtual item, so it still re-parses + re-lays-out in full while any part is on screen; the parse-memo lever (memoize parsed blocks per turn, keyed by text) would close that last case. Low priority — needs a genuinely giant single message to bite. |
| OFI-120 | The Flare paint loop emitted EVERY recorded leaf every frame, even ones scrolled far outside the viewport — a long chat message (≈3000 lines) produced ~6000 `draw_text` ops/frame at `y` as negative as -96417, each one FreeType-shaped before raylib clipped its pixels away. Diagnosed from a live `EMBER_TAPE` capture of the Claude app: a 717 MB tape, 1241 frames, mean 4908 draws/frame, steady-state 6132 of which only ~161 were on-screen (5854 off the top). The renderer relied on the GPU clip rect for correctness but did the per-line CPU shaping work unconditionally — O(content) per frame instead of O(visible). | **CLOSED 2026-06-22** (raised by Karl: "really slow dumping 3000 lines into a textbox"; root-caused via the new `EMBER_TAPE` hook in the app — see [[ember-claude-app]]). Added viewport culling to `finish()` (std/flare.em): a scroll viewport (`_SCROLL_BEGIN`) records its screen-space bounds `[vtop,vbot]` and arms a `cull` flag; each leaf whose final `[y,y+h]` is fully outside the viewport is SKIPPED (no `_paint`, no rect record) — partially-visible rows still paint, so no clipping artifact. ~6132 → ~270 draws/frame on the reported case (~22×; the giant message's text ops 6023 → 161, ~37×). `flare_fab`/`flare_sticky` goldens re-blessed (now assert only the visible tail; the FAB shape — a high-layer leaf anchored on-screen — is preserved byte-identical) and double as the cull regression; graphics 36/0. Also wired `EMBER_TAPE=/path` into `flare_chat.em` (env-gated, one JSON line/frame, `tail -f`-able). Follow-up OFI-121 tracks the remaining per-frame re-parse cost. |
| OFI-119 | Every padded control in Flare (`button`/`primary`/`ghost`, `nav_item`, menu items, ghost label, tab chips, dock title bars, the drag ghost) vertically centred its text with `y + (h - text_size) / 2`, but `draw_text(y)` places the font's full LINE BOX (ascender + descender) at `y`, and the line box is ≈1.2× `text_size`. Centring a `text_size`-tall slab inside a box leaves the extra descender space *below* the glyphs, so the visible caps read consistently LOW — text sits closer to the bottom than the top (Karl, from a live Settings-dialog screenshot, then again on the Recents list). std/ui already centred fields/areas on the line box; the Flare paint arms didn't. | **CLOSED 2026-06-22** (Flare visual-polish campaign; raised by Karl from the live app). Added one shared helper `Flare._ty(boxy, h, size) -> boxy + (h - text_line_height(size)) / 2` (std/flare.em) and routed EVERY padded-control paint site through it (`_paint_button`, `_paint_nav`, `_GHOST`, `_MENUITEM`, the tab chip, dock title, drag ghost) so they all centre on the true line box and can't drift apart again. Inline/tight text (`_LABEL`/`_MUTED`/`_HEADING`/rich-text runs) deliberately untouched — line-box centring would push them out of their snug boxes. Verified with the tape: shapes byte-identical, text up exactly 2px, bar-height nav rows now off-by **+0px** (card centre 56 = line-box centre 56). 6 graphics goldens re-blessed (text-`y` only); graphics 36/0. |
| OFI-116 | A `nav_item` STOPPED ellipsizing its title while a popover/modal was open — every background nav row rendered its FULL title and overflowed its pill (Karl's screenshot: clicking a conversation's "···" opened "Delete chat" and the long selected title spilled past the accent pill). The inert gate `if !(self._modal && !self._in_modal)` wrapped BOTH the click-press AND the last-frame WIDTH read (`w_last = r.w`) that drives the ellipsis, so an open overlay zeroed `w_last`, `_fit_text` was skipped, and the full text drew. | **CLOSED 2026-06-22** (raised by Karl from the live app). Split the gate in `nav_item` (std/flare.em): the `w_last` width read now happens for EVERY recorded rect, and only the `ui.press` (the click) stays behind the inert gate — so ellipsis survives an open popover while click fall-through is still suppressed. Reproduced + verified with a dogfood + `EMBER_CAPTURE` (long title overflowed the pill with the popover open → ellipsizes after). Regression `tests/graphics/flare_nav_popover.em` (taped settled frame asserts the trailing "…"); graphics 33/0. |
| OFI-115 | Atomic widgets (`f.button`/`f.primary`/`f.ghost_button`) STRETCH to full width when placed directly in a `STRETCH` parent (the default root column) — a bare button spans the whole window instead of sizing to its content (a newcomer hits this immediately; was visible in `18_flare_anim`'s "Toggle width"). Text/divider widgets SHOULD fill width (to wrap/centre/rule); atomic action widgets should not. | OPEN (filed 2026-06-22, Flare visual-polish campaign). Fix = give button/primary/ghost an intrinsic cross-axis size so flexbox `stretch` can't expand them. Deferred deliberately: the Claude app (`flare_chat.em`) leans on current stretch behaviour, so verify before/after with the new `EMBER_CAPTURE` instrument under `net-graphics` first. Worked around in examples by wrapping bare buttons in a `row`+`spacer`. |
| OFI-114 | The LIGHT theme was not at parity with dark: panel TITLE BARS were drawn as `ui.shade(st.panel, 6)`, but `panel` is pure white in light so `+6` CLAMPED to white and the bars vanished — a theme-POLARITY bug (the same shade direction can't read on both grounds); compounded by a too-faint border and a weak shadow (α22) so light panels neither delineated nor lifted. | **CLOSED 2026-06-22** (Flare visual-polish campaign). Added an explicit per-theme `bar` surface token to `ui.Style` (a step lighter than panel on dark, a step darker on white), used at the dock title bar (std/flare.em:1019); retuned `theme_light` (stronger border `d4cfc6`, shadow α22→34, page bg nudged warmer so white panels lift). Verified with the new `draw.capture`/`EMBER_CAPTURE` instrument — the light dock now reads with dark's clarity, dark unchanged. Also added a `gutter` token (page-edge inset for top-level content, distinct from `pad`) wired to the root column. 30 graphics goldens re-blessed (gutter+border deltas only). |
| OFI-113 | A single-line `f.label`/`f.text_muted`/`f.heading` whose text exceeded its box drew the FULL string off-screen (past the window edge) instead of clipping — `_paint` called `draw_text(text, …)` with no width bound (e.g. `17_flare`'s description spilled out of the window). The robustness gap a polished toolkit closes with `text-overflow: ellipsis`. | **CLOSED 2026-06-22** (raised + fixed at Karl's request). `_paint` now ellipsizes to the SOLVED box width `w` at paint time — exact, no 1-frame lag (the layout clamps an oversized leaf to its container, confirmed via capture). Reused the existing kerning-correct `_fit_text`, generalised to `_fit_text_sz(s, max_px, sz)` so headings fit at their larger size; short text is untouched. Regression `tests/graphics/flare_ellipsis.em` (graphics 31/0). |
| OFI-111 | Runtime Fault precision + repro follow-ups (docs/faults.md Phase 2/3): (a) `where` is line-only — the runtime keeps no per-byte COLUMN table (`Chunk.lines` is line-only) and no per-function SOURCE PATH (`Function` carries only a name), so there is no caret and `where.file` is the ENTRY path (the `fn` name disambiguates multi-module); (b) the recursive struct/enum VALUE WALKER is unbuilt, so a non-scalar value (an `Err` payload) would render `<obj>` not `Err("io")`; (c) a `u64` overflow operand is shown as its two's-complement i64 view (the shared `overflow_fault` takes `int64_t`); (d) the deterministic `repro` field (re-run the SAME inputs to verify a fix) is not attached. | OPEN (Phase 2/3, filed 2026-06-22). (a)+(b) are the literature's precision/values levers at full strength; (c) is a minor cosmetic wart; (d) is gated behind OFI-044 (string-FFI replay is unfaithful, so repro is premature for the apps that need it). Honest-cost order: value walker → columns/per-fn file → repro. |
| OFI-110 | Compile-side Fault convergence (docs/faults.md). Bring every failure class onto the one Fault schema: (a) CONTRACT violations, (b) an `Err`/`None` reaching `main` (FCAT_UNHANDLED_ERR), (c) type/parse compile diagnostics → the agent Fault render + a real `Token` byte-span + the `severity` enum, (d) `--check` counterexamples. | **PARTIALLY CLOSED 2026-06-22.** (a) DONE — `OP_CONTRACT_CHECK` now renders via `contract_fault` (category=contract, code, call-stack route) on the unified channel; the synthesized message + `contract_violation` tape event are unchanged, so the `--check` classifier (string-matches the message) stays correct (verified: check stage green). (b) DONE — `report_unhandled_error` (src/main.c) detects an Err/None main returns unhandled via the prelude Result/Option identity recorded at codegen (CompiledProgram.result_enum_id/err_tag/…), renders an FCAT_UNHANDLED_ERR Fault with the error value + the OFI-108 route, and exits non-zero (was: exit 0 + `=> <obj>`). Regressions `tests/run/error_unhandled_err.em`, `tests/fault/unhandled_err.em`. **STILL OPEN: (c)** compile-diagnostics→agent-Fault render + byte-spans + severity wiring — LOWER PRIORITY: `--diagnostics=json` already serves an LLM structured compile errors (file/line/col/message/near/help/note), and the compile Diag's near/note don't map cleanly onto the Fault's values/route, so the marginal gain is a unified agent flag, not a capability. **(d)** `--check` counterexamples → Fault (the tape already structures them). |
| OFI-109 | Native-backend (AST→C) Fault parity: rich Faults are VM-only. A natively-compiled binary (`emberc -o`) still aborts via `em_panic` (a bare string + `exit(70)`), with no frame/line table, no route, and contracts not emitted at all (`cgen_c.c`). The differential test compares STDOUT (Faults go to STDERR), so a native/VM Fault-render divergence is invisible to the existing drift guard. | OPEN (umbrella, filed 2026-06-22). Decide once: formally scope rich Faults to the VM and document native as "bare `em_panic` message", OR thread line/values/ctx into `em_panic` + emit native debug-profile contracts; either way extend the differential harness to compare the stderr Fault render so native drift is caught. Exit-code split (VM 65 vs native 70) lives here too. |
| OFI-108 | The Fault `route` was only the synchronous CALL-STACK backtrace, useless for an `Err` reaching `main` (the propagating frames have already unwound). Add the Zig-style `?`-PROPAGATION error-return-trace (each `?` hop the Err travelled). | **CLOSED 2026-06-22.** New release-elided `OP_ROUTE_HOP` emitted on the `?` (EXPR_TRY) failure branch records `(fn, line)` into a bounded in-VM ring (`vm->route_hops`, cap FAULT_MAX_HOPS); the unhandled-Err-at-main Fault attaches it via `vm_route()`. KEY simplifications vs the workflow design: the hop stores only `(fn,line)` (the Err VALUE is shown once in the Fault's `values`, so NO value-snapshot → the use-after-free vector is moot), and the buffer is cleared at every CALL (a call can't occur while a `?` chain unwinds, so it ends any prior handled chain) — replacing the fragile depth-reset heuristic, verified against a handled-then-propagate case (route correctly excludes the handled chain). VM-only (the in-VM ring sidesteps the parallel tape-sink `fprintf` race; native is OFI-109). opcheck ✓ (new opcode), ledger 300/300, crucible 187/187, ASan clean. Regression `tests/fault/route_chain.em`. The hop carrying the propagated value at each step is a deferred refinement (needs the OFI-111 value walker). |
| OFI-107 | `src/trace.c`'s `json_lines_on_event` emitted every string field — the semantic-event `detail` (a contract message), string stack values, names — with a **bare `%s`**, so any string containing a `"`, newline, or control byte produced INVALID JSON Lines AND could inject control/ANSI bytes into the tape, a channel an LLM consumes (an injection vector). It sat in the EXACT value-projection path the Fault campaign builds on. | **CLOSED 2026-06-22** (Phase 0 of the Fault campaign) — extracted the one true JSON-string escaper into `src/jsonw.c` / `include/jsonw.h` (`json_write_string`: escapes `"`, `\`, and every C0 byte) and routed BOTH the tape (trace.c, every string field) and the diagnostics JSON (diag.c, which had its OWN private `put_json_string` — now deleted) through it, so the two can never drift again. Regression `tests/trace/string_escape.em` (a value carrying `"`, newline, tab, `\` → valid escaped JSON, Python-parsed every line). `make test` 372/0; `--diagnostics=json` + existing tape goldens byte-identical. |
| OFI-106 | The native backend (`src/cgen_c.c`) emits the embedded `StructType` table as a POSITIONAL C initializer (`{ 0, field_count, total_size, off, knd, fst }`), so adding a field to `StructType` in `include/program.h` silently MISALIGNS every emitted struct and breaks the generated C (caught only by `cc` — an `int[2]`-into-`int` error — across the whole native suite). Hit while adding `is_rc` for `rc struct`. The VM path is fine (it copies field-by-field in `codegen.c`); only the emitted-C initializer is positional. | **CLOSED 2026-06-23.** The emitted `em_structs[]` table now uses a DESIGNATED initializer per entry (`{ .field_count = …, .total_size = …, .is_rc = …, .offset = …, .kind = …, .field_struct = … }`, src/cgen_c.c) — a future `StructType`/`StructLayout` field can no longer silently misalign the table; an omitted field just zero-inits (`.name` is unused at runtime → NULL). A guard-comment warns against collapsing it back to positional. Verified: the emitted C is designated (confirmed on a value-struct array), compiles under `-Werror`, VM==native, full native suite 384/0. |
| OFI-105 | The dependency-free `make test` (tests/run.sh) FAILED `tests/net/anthropic_harness.em`: run.sh's stage loop skips `graphics`/`parallel`/`native` (each needs a special build) but NOT `net`, so the net stage ran under the plain compiler where `std/http`'s libcurl externs are 'unknown C function', and — falling to `emit_flag`'s default `tokens` — diffed a 643-line token dump against a run-output golden. `tests/run-net.sh`'s own header already documents net as "kept OUT of the dependency-free default suite", so run.sh simply lacked the skip. | **CLOSED 2026-06-21** (toward v0.3.40) — added `[ "$stage" = "net" ] && continue` to tests/run.sh mirroring the graphics/parallel skips; net coverage is unchanged (driven by `make test-net` → tests/run-net.sh under `build/emberc-net`). `make test` is green again (365/0). Surfaced while regression-testing OFI-100..104. |
| OFI-104 | `codegen.c` leaks per-struct `field_names` arrays on the SUCCESS path. `codegen_program`'s success exit does a bare `free(cg_structs)` (src/codegen.c:2592) — frees the table but NOT each entry's `field_names` vector (malloc'd by `alloc_field_names`) — whereas the error path correctly calls `free_cg_structs(cg_structs, total_structs)` (src/codegen.c:2577; helper ~2388). | **CLOSED 2026-06-21** (toward v0.3.40) — replaced the bare `free(cg_structs)` on the success path with `free_cg_structs(cg_structs, total_structs)` (src/codegen.c:2592), matching the error path. Reviewed solid: no double-free (each entry's `field_names` is independently malloc'd; all `total_structs` entries are initialised before either free site). A process-exit cleanup leak with no runtime growth — and since LSan is unsupported on this machine there is NO automated leak gate; verified by inspection + an ASan-clean manual run ([[ember-asan-available]]). The one knowingly-untested fix of the batch. |
| OFI-103 | `std/string.repeat(s, n)` infinite-loops for any negative `n`. The loop's only exit is `if i == n { return concat(out) }` with `i` starting at 0 and only incrementing (std/string.em ~52-61, guard at line 56), so a negative `n` is never reached and the loop appends `s` unboundedly (hang / OOM). | **CLOSED 2026-06-21** (toward v0.3.40) — changed the loop guard to `if i >= n` (std/string.em:56) so any `n <= 0` returns `""` immediately. Regression `tests/run/string_repeat.em` (+ golden) covers n=3/0/-2; VM==native, both emit `a=[ababab] b=[] c=[]`. Reviewed solid — `repeat` was the only `==`-against-a-user-supplied-bound loop guard in string.em (every other compares `i` against a non-negative `.len()`). |
| OFI-102 | The LSP server can be crashed/OOM'd by malformed editor input via TWO vectors: (1) `lsp.c` `read_message` (~lines 57-74) validates `Content-Length` only with `< 0`, then `malloc((size_t)content_length + 1)` with no upper bound and no NULL-check — a huge/garbage length OOMs or segfaults; (2) `json.c`'s recursive-descent parser (`parse_value`/`parse_array`/`parse_object`, ~201-292) has NO recursion-depth limit, so deeply-nested JSON blows the C stack. | **CLOSED 2026-06-21** (toward v0.3.40) — BOTH vectors closed: `lsp.c` `read_message` now rejects `Content-Length` <0 or >64 MiB and NULL-checks the malloc; `json.c` gained a `Parser.depth` field + `JSON_MAX_DEPTH`(1000), with `parse_value` split into a depth-guarded wrapper over `parse_value_inner` (the serve loop already treats parse→NULL as skip and read→NULL as EOF, so no NULL-deref). Regression in `tests/run-lsp.sh` (`make test-lsp`): an absurd `Content-Length` is rejected and a 100000-deep JSON message is capped — the server survives and keeps serving the next request. LSP/tooling-only (not the language). |
| OFI-101 | The contract prover's atom buffer can be overrun by a long `ensures`/`requires` clause. `prove.c` sizes the per-clause conjunct buffer at `PROVE_MAX_ATOMS` (32) but `add_atom`'s overflow guard checks against `PROVE_MAX_CONSTR` (128) — the WRONG constant — so a clause with 33..128 conjuncts writes past the 32-slot stack array (decl ~line 400; guard ~194-201; fill loop ~224-247). A stack-buffer overflow reachable from the LSP prover path and `--emit=check`. | **CLOSED 2026-06-21** (toward v0.3.40) — threaded a real `cap` parameter through `add_atom`/`clause_to_constraints` (src/prove.c); the requires site passes `PROVE_MAX_CONSTR`(128, `req[]` size), the ensures site `PROVE_MAX_ATOMS`(32, `atoms[]` size), so a >32-conjunct clause is bounded (reported unproved) instead of overrunning the stack. Regression `tests/prove/prove_long_clause.em` (40 conjuncts → clean 'not proved (use --check)', no crash). Reviewed solid: the `TOK_EQ` double-add is safe at the boundary, and soundness is preserved (an over-long clause conservatively under-proves, never falsely proves). |
| OFI-100 | The checker's `unreachable` dataflow flag LEAKS across function boundaries, silently disabling the linear-`Ptr` leak scan for any function declared AFTER one whose body ends in a diverging `return`. `check_callable` (src/check.c) raises `c->unreachable = 1` at body-end when a top-level statement diverges (~line 6388) but its per-function reset block (~6295-6297: local_count/scope_depth/loop_depth) never lowers it — whereas `check_lambda` (line 6101) DOES. The end-of-body leak scan is gated on `!c->unreachable` (line 4908), so the next function inherits `1` and its un-closed `Ptr` handles escape the 'opened but not closed' check. A declaration-order-dependent re-opening of the OFI-049 must-consume guarantee. (Secondary: `c.unreachable` is also never initialised in `check_program`'s Checker init, so the FIRST function reads indeterminate stack — subsumed by the same fix.) | **CLOSED 2026-06-21** (toward v0.3.40) — reset `c->unreachable = 0;` at `check_callable`'s per-function entry (src/check.c:6298, mirroring `check_lambda`:6101) and initialised it in `check_program` (:7673), so the diverging-return flag no longer bleeds across functions and skips the linear-`Ptr` leak scan. Regression `tests/run/error_ptr_leak_after_return.em` (a leaking-`Ptr` fn after a `return`-ending fn — compiled clean pre-fix, errors after) **plus `tools/ledger.sh` extended** to prepend a `return`-ending function to every reject seed, so the cross-function bleed is now fuzzed (`make ledger` 300/0). CONFIRMED via the committed git baseline after a skeptic FALSE-refuted it on a contaminated shared tree (the lesson: mutating verifiers need worktree isolation). Adversarial review flagged `check_lambda` as a sibling hole but it was DISPROVED — its body loop never calls `stmt_diverges`/raises `unreachable`, so a diverging lambda cannot poison the enclosing scan (verified in code + by a pre-fix binary). [[ember-ledger]] |
| OFI-099 | The linear `Ptr` must-consume obligation is minted ONLY by a direct extern-call result, NOT by a USER function whose declared return type is `Ptr`: `fn opener() -> Ptr { return fopen(...) }  let p = opener()` (never closed) compiles CLEAN, whereas the direct `let p = fopen(...)` is correctly flagged 'opened but not closed'. A genuine OFI-049 leak-detection gap. | **CLOSED 2026-06-23 — found ALREADY FIXED on verification.** Reproduced the exact case (`fn opener() -> Ptr { fopen(...) }; let p = opener()` unclosed): the checker now correctly mints the must-consume obligation on a user `fn → Ptr` result and flags it 'opened but not closed' — verified for the named binding, the `let _ =` discard, AND that a properly-closed wrapper stays clean (not over-strict). The obligation evidently rides the declared-return-type path now; the OFI-095-era gap was closed incidentally by a later linearity change. Locked with regression `tests/run/error_ptr_leak_wrapper.em` (symmetric to `error_ptr_discarded.em`); run-suite 382/0. *Lesson: the log was stale — verifying against the baseline beat trusting the filed claim.* |
| OFI-098 | A binding named exactly `_` is a discard only at FUNCTION-LOCAL scope: a module-scope `let _ = 42`, `fn _(...)`, `struct _{...}` stay ordinary readable/callable/constructable global symbols (top-level resolution is a separate path OFI-095 didn't touch). A least-surprise/consistency gap for the LLM-first goal — NOT a soundness issue (`is_public_name("_")` still classifies it private cross-module; VM==native; no corpus relies on it). | OPEN (surfaced by the OFI-095 review). docs/language.md frames the discard as a local binding; resolve fully by either making top-level `_` a discard too, or documenting local-only explicitly. Low priority. |
| OFI-097 | LSP rename/find-references mis-targets a DUPLICATE bare `_` on one source line: `find_name_col` (src/lsp.c:1698) returns the first whole-word match and `collect_references` (src/lsp.c:1724) keys a symbol by `(def_file, def_line, spelling)` only, so renaming the SECOND `_` of `fn f(_: int, _: int, x: int)` edits the FIRST. Newly EXPOSED by OFI-095 (two `_` on one line was a redeclaration error before). | OPEN (surfaced by the OFI-095 review). Cosmetic: only ever mis-edits a meaningless write-only discard, never a real identifier (whole-word matching excludes `_foo`; renaming real vars on a shared line works). Fix: rename/prepareRename should REFUSE a bare `_` (unnameable by design), or make `find_name_col` column-aware via the cursor anchor. LSP-only. |
| OFI-096 | The NATIVE backend (AST→C) **leaks** the result of a bare expression *statement* that yields an owned temporary: `STMT_EXPR` emits `(void)(E);` and ignores the checker-set `release_temp`, so a discarded fresh string/array/struct is never `drop_value`d — whereas the VM correctly emits `OP_RELEASE`. A live VM-vs-native divergence + leak (e.g. `mk("x")` on its own line: native leaks, VM frees). | **CLOSED 2026-06-23.** Native `STMT_EXPR` (src/cgen_c.c) now reads `s->as.expr.release_temp` and, when set, emits `{ Value _dis = (E); drop_value(&g_em, _dis); }` instead of `(void)(E)` — mirroring the VM's `OP_RELEASE` (codegen.c). No value-struct special-case was needed in the end: `drop_value` is the SAME call `emit_drops` already uses for every owned binding (it releases a value-struct's heap fields too), and `release_temp` is only set for genuine owning temps, so the two backends discharge identically. Verified three ways: the emitted C now drops the discarded `mk("x")`; the native differential is VM==native (so the added drop is not a double-free — it would crash the binary); and an RSS probe (2,000,000 discarded strings → **1.4 MB** RSS, flat — would be ~64 MB if leaking) confirms the silent leak is gone (native ASan/LSan still not wired). Regressions `tests/run/discard_expr_drop.em` (VM) + `tests/native/discard_expr_drop.em` (differential); full suite 384/0. |
| OFI-095 | `let _ = expr` — the discard idiom every mainstream language spells with a re-bindable wildcard — **cannot be repeated in a scope**: Ember binds `_` as an ordinary variable, so a second `let _ = …` errors with `redeclaration of a variable in the same scope`. An LLM writing Ember reflexively repeats it (Rust/Go/Swift/Python all treat `_` as a throwaway wildcard) and hits a confusing error that never mentions `_` or discarding — a least-surprise-for-the-model miss (MANIFESTO LLM-first). | **CLOSED 2026-06-21** (checker-only, 2 edits in src/check.c: `declare_local` exempts the EXACT name `_` from the same-scope redeclaration check — still allocates a slot, so an owned value drops at scope exit and a discarded linear `Ptr` is still flagged; `resolve_local` returns -1 for exact `_`, making it write-only (reading `_` → 'undefined variable'). Leading-underscore names (`_foo`/privacy, OFI-081) untouched via an exact `name[1]=='\0'` guard. Chosen over the heavier AST+parser+both-codegens rewrite the design workflow proposed, because today's `let _ = E` ALREADY drops owned values correctly and ALREADY errors on a discarded Ptr — only the redeclaration + readability were wrong; this smaller fix also corrects `fn f(_, _)` params and `case Pair(_, _)` for FREE (shared choke points). Designed via a 6-agent understand-map workflow; adversarially verified by a 6-agent review (**ship-with-followups, 0 real defects**) + Ledger 300/0/0 + Crucible clean + 362 golden suite + full LSP regression + VM==native byte-for-byte + ASan-clean. Boundary kept: `let _ = unitCall()` still errors (can't bind a no-value call — already documented). Regressions: `discard_wildcard`, `error_discard_read`, `error_discard_ptr_leak`, `discard_ptr_close`. Docs: language.md. Follow-ups filed: OFI-097/098/099.) |
| OFI-094 | OFI-092 follow-ups (Karl, with a screenshot): the resized sidebar pills (a) TRUNCATED the title far too early — a big empty gap before the "…" — and (b) the Settings entry rendered as a GIANT tall pill | **CLOSED 2026-06-21** ((a) two causes: `title_for` PRE-CAPPED the stored title at 24 chars (→ 80; each view ellipsizes its own way) AND nav_item truncated by a conservative CHAR budget; nav_item now **ellipsizes to its real PIXEL width** via `_fit_text` (binary-searched over substring measurements — kerning-correct, ~log n measures, the widget-level `text-overflow: ellipsis`) using LAST frame's painted width (1-frame lag like text_area's auto-grow), so long titles FILL the pill and scale with the splitter (220px→"Explain a tricky c…", 480px→full); the app dropped its `name_max` hack. (b) a bare `nav_item` in the sidebar COLUMN grew `grow=1` DOWNWARD → wrapped Settings in a `row` so it grows WIDTH, one row_h tall. Regression `tests/graphics/flare_nav_ellipsis.em`; graphics 26/0, flare_chat compiles. FOLLOW-UP (Karl: "still not expanding on resize"): the width fix worked but EXISTING conversations didn't visibly improve — the old store had baked the 24-char "…" INTO the persisted title string, so there was no hidden text to reveal. Fix = re-derive `title_for(lt)` from the loaded TURNS on load (the full first message is in `turns`), ignoring the stale stored title; the store self-heals on next save. Diagnosed by reading ~/.ember-claude-history.json, not guessing — `'Explain a tricky concept…'` (stored) vs `'Explain a tricky concept simply'` (turn[0]).) |
| OFI-093 | Flare had NO animation — every state change SNAPPED (panels popped in, list rows teleported on add/delete), the biggest perceived-quality gap vs modern UIs (the "next-level" research's Tier-4) | **CLOSED 2026-06-21** (spring physics + FLIP layout transitions on the keyed-state surface, over a FIXED timestep so animation is a pure function of FRAME COUNT — deterministic + golden-testable, no `clock()` nondeterminism in the render path; decision in docs/architecture.md). New: float-state column `sf` + `state_float`/`set_float`; **`f.spring(key,target)`/`spring_with`** (semi-implicit Euler over (pos,vel); snap-on-first-sight, retarget-for-free, rest-threshold settle); **`f.at(dx,dy)`/`end_at`** (a pure paint-queue offset bracket — `finish()` accumulates a 2-axis offset over a nesting stack, generalizing the scroll y-shift); **`f.animate_layout(key)`/`end_animate_layout`** (FLIP — springs the per-frame solved-position JUMP to zero at paint time off the EXISTING last-frame rect cache, never feeding back into the solve; the standout, nearly free because Flare re-solves flexbox every frame). Proven via the tape (a panel slides −290→10 tracking the spring; a pushed row eases 14→80 and settles, no teleport/drift). Regressions `tests/graphics/flare_spring.em` + `flare_flip.em` (exact deterministic curves), demo `examples/graphics/18_flare_anim.em`; graphics 25/0, no regression. docs/flare.md gained an Animation section.) |
| OFI-092 | The sidebar conversation list did NOT resize with the splitter (OFI-085): each Recents entry was a content-sized `f.button`/`f.primary` in a `START`-aligned panel, so widening the sidebar left the pill narrow with a big gap to its right — "looks pretty odd" (Karl, with a screenshot). The kit had no full-width nav primitive | **CLOSED 2026-06-21** (new **`f.nav_item(txt, active) -> bool`** — a full-width sidebar row that GROWS (`leaf(w,h,1)`) to fill the panel width and paints LEFT-aligned (vs the centred `_paint_button`), accent fill when active; `_NAVITEM`/`_NAVITEM_ON` kinds + `_paint_nav`. flare_chat: sidebar panel `START`→`STRETCH` so the rows fill (heading wrapped in a `row` to stay left, since a bare heading centres under STRETCH), conversation rows use `nav_item` + the trailing ghost "···", and the title ellipsis budget now SCALES with `sbw`. Proven via the UI tape: nav card width 153→313 as sbw 200→360 (tracks the delta), accent vs panel fill, left-aligned text, "···" pinned right. Regression `tests/graphics/flare_nav_item.em`; graphics 23/0. A genuinely reusable nav primitive the kit lacked — surfaced dogfooding the resizable sidebar.) |
| OFI-091 | `spawn` rejected a MODULE-QUALIFIED callee — `spawn mod.worker(args)` failed the checker with "'spawn' requires a call to a named function", because the spawn validation only accepted a bare-identifier (`EXPR_IDENT`) callee. This blocked the headline goal of a *library* providing a spawnable fiber (surfaced extracting flare_chat's `stream_worker` into the reusable `anthropic` client over `std/http`) | **CLOSED 2026-06-20** (the spawn check now resolves a qualified callee `mod.fn` exactly as a qualified DIRECT call does — `resolve_qualified_fn` after the `EXPR_GET` / non-local-alias test — for the named-function + not-extern guards; `check_expr` then caches `resolved_fn`/witnesses on the node, which BOTH backends already read unchanged (verified: codegen.c spawn and cgen_c.c `emit_spawn` both key off `resolved_fn`, never the callee kind). A pure checker fix, ~12 lines, zero backend change. VM==native verified (`got 42` on both). Regression `tests/run/spawn_qualified.em` (+ `modlib/worker.em`). Found + closed dogfooding the std/http extraction; decision logged in docs/architecture.md.) |
| OFI-090 | No `remove_at(i)` — deleting an element from the middle of an array meant a hand-rolled rebuild loop (the genuinely-missing primitive OFI-072's cost/benefit flagged; per-chat delete wanted it) | **CLOSED 2026-06-20** (new `arr.remove_at(i) -> T` intrinsic: removes + returns element i, shifts the tail down O(n), bounds-checked, both backends. Wired the 8 sites with a SINGLE-SOURCED `ARR_OP_*` enum in ast.h (was magic 1/2/3/4 across check.c/codegen.c/cgen_c.c — the "same number in 4 places" trap). **Tool:** extended Crucible to fuzz array-mutation methods (`op_array_remove_at`/`op_array_remove_last` on value-struct arrays, 21/60 seeds hit it) → the whole class now rides the 5 oracles repeatably. Dogfooded: flare_chat per-chat delete = 15-line rebuild → one `remove_at` (no deep-clone-all). VM==native, ASan-clean, Crucible 120/120, opcheck clean. Regression `tests/run/array_remove_at.em`. Through-index receiver stays the OFI-072 error.) |
| OFI-089 | Under M:N a GUI app's render loop (raylib/Cocoa) must run on the OS MAIN thread, but a fiber can run on any worker | **MITIGATED 2026-06-20** (vm_run runs the MAIN fiber DIRECTLY on the calling thread = worker 0, helpers handle spawned fibers — so the render loop, which never parks, stays on the main thread. Fixed the startup trace-trap when the Flare app ran on `make mn-net-graphics`.) Residual: if main PARKS then resumes (e.g. a final nursery join at window-close while a fetch is mid-flight) it could resume on a helper → an off-main-thread raylib call. Full fix = PIN main to worker 0 across park/resume (a dedicated worker-0 slot). Low urgency; the render-loop-in-nursery-body pattern never parks main mid-run. |
| OFI-088 | Under M:N a `Fiber` embeds a full `Value stack[STACK_MAX]` (~64KB) — fine for thousands of fibers, but 100k = ~6GB | OPEN (perf/scaling; the headline "100k cheap fibers" tier needs right-sized or segmented/growable fiber stacks. Thousands work today. Filed by OFI-071.) |
| OFI-087 | M:N ready-queue is ONE global mutex+condvar MPMC queue, not per-worker work-stealing deques | OPEN (perf; correct + simplest-first per the measurement-first discipline — delivers "thousands of cheap fibers". Work-stealing needs a distributed termination-detection algo to keep the no-false-negative deadlock guarantee. Measure before building. Filed by OFI-071.) |
| OFI-086 | `send` on a CLOSED channel had no defined policy — serial/1:1 silently enqueued (if room) or parked forever (if full); only M:N errored | **CLOSED 2026-06-20** (DECISION: send-on-closed is a runtime error on ALL three runtimes — "send on a closed channel" — like Go's panic and consistent with Ember's other programming-error traps (overflow, bounds). Added the `ch->closed` check to the serial + 1:1 `OP_SEND` arms and native `em_channel_send`; M:N already had it. Regression `tests/run/error_send_closed.em`.) |
| OFI-085 | No **resize/split control** in the UI stack — panes were fixed-width (the Flare app's sidebar was a hard-coded 236, duplicated in two places); no way to drag-resize like every real app | **CLOSED 2026-06-20** (new `std/flare.splitter(key,size,lo,hi,vertical)` + engine `std/ui._split_drag`, an absolute-anchor drag latch with its own non-aliasing fields; a VM-only tape-silent `set_cursor` builtin gives the ↔/↕ resize pointer. Wired to the Claude app sidebar — `sbw` is now a single persisted `state_int` the splitter drives (236 no longer duplicated), max window-aware. Designed via a 3-spec judge-panel workflow, then adversarially reviewed (5 dims → per-finding verify) which caught + fixed a modal-gated-latch leak, a `w>=h` paint heuristic, and a narrow-window overflow. Tests: `tests/graphics/splitter.em` (latch math, both clamps, before/vertical paths, release) + `tests/graphics/flare_splitter.em` (widget + `_SPLIT` paint + resize). graphics 22/22, default 351/0) |
| OFI-084 | Rendered code blocks (and all read-only text) were **unselectable** — a Copy button was the only way to get the text out, unlike every editor/browser where you drag-select + Ctrl/Cmd+C | **CLOSED 2026-06-20** (code blocks are now selectable: new read-only selection layer in `std/ui` (`_code_input` + `code_caret_at` + `pressed_down` down-edge) reusing the existing field focus/caret/anchor/clipboard machinery; `std/flare`'s `_paint_code` draws a translucent selection highlight behind the syntax-highlit glyphs. Drag-select, Shift, Ctrl/Cmd+A (select-block), Ctrl/Cmd+C (copy). The Flare Claude app inherits it for free via `f.markdown`. Scope = per-block (Karl's call); whole-document continuous selection across prose+code is the deferred next tier. Regression: `tests/graphics/flare_code_select.em`) |
| OFI-083 | `.slice()` on a VALUE-STRUCT array (`convos[i].turns.slice(…)`) corrupted memory — `OP_SLICE_COPY`/`em_array_slice` sized the copy at `sizeof(Value)`/element (`alloc_array` by `elem_kind`) instead of the struct's `total_size`, so the `memcpy` of `n*elem_size` overran the buffer (a heap-buffer-overflow → abort/double-free at teardown; the earlier "infinite loop" symptom was the same mis-size, since fixed elsewhere) | **CLOSED 2026-06-20** (slice an inline-struct array via the struct-aware `alloc_struct_array(n, elem_struct_id)` so `o->elem_size == a->elem_size`; the existing `struct_elem_retain` then shares the boxed leaves with a correct refcount — no double-free. BOTH backends. ASan-clean, Crucible 60/60 clean. Regression `tests/run/slice_value_struct.em` (field-receiver slice, VM==native). `.clone()` is still the deep-copy; slice is now a sound shallow copy with refcounted leaves.) |
| OFI-074 | The "value moved inside a loop body" guard rejected an UNCONDITIONAL `consume(x); break` — it checked the body-END moved-state, which carries a stale move on an already-exited (break/return) path that never recurs | **CLOSED 2026-06-20** (the guard now tracks moved-state at the actual LOOP BACK-EDGES — every `continue` plus a *reachable* fall-through — OR-accumulated, and reports only a move that reaches one. New `Checker.loop_backedge_moved` accumulator, the move dual of the `loop_break_consumed` Ptr pattern; applied to both `loop` and `for`. Sound: a move that maybe-breaks (recurs on the else path) or precedes a `continue` is still rejected. Ledger 300/300 (0 unsound, 0 over-strict). Regressions `tests/run/loop_move_break.em` (+`for`) and `error_loop_move_recur.em`.) |
| OFI-073 | Enum **variant names were globally unique across all enums** — two co-imported modules couldn't both define a `Str`/`Node`/`Value` variant, and an imported enum's variants couldn't be constructed | **CLOSED 2026-06-19** (full fix, BOTH backends, Crucible/ASan/dual-run verified). (1) *Collision:* the uniqueness check is now module-scoped to mirror `resolve_variant`'s visibility — conflicts only within a module or against a prelude enum (so `std/json`'s `Str` and `std/highlight`'s `Kind.Str` coexist; redefining built-in `Ok`/`Some` is still caught). `match` was already scrutinee-directed. (2) *Soundness:* relaxing the check exposed that codegen resolved variants by GLOBAL name (`resolve_cgvariant`), so a same-named variant of the wrong enum/arity could be built — fixed by threading the checker-resolved `(enum_id, variant_tag)` onto the AST (Expr + Pattern) and having both backends build/dispatch from THAT, not a by-name lookup. (3) *Stage 2:* cross-module construction `json.Obj([…])` now resolves (`resolve_qualified_variant`), so library enums need no builder boilerplate. Regressions: `variant_cross_module` (+native), `variant_qualified_construct` (+native). |
| OFI-072 | `arr[i].append(x)` / `arr[i].field.append(x)` **silently no-ops** — a `mut self` method whose receiver is reached through an index mutates a temporary, not the stored element | **APPEND FIXED 2026-06-19** in BOTH backends (read-modify-write: append into the read-out copy, then write the whole array back via the assignment store path). ASAN-clean, VM==native dual-run parity, regression-locked. `remove_last` through a copy stays a **compile error** (no silent loss). *Its RMW was attempted + reverted (2026-06-19):* the native backend works (C statement-expression yields the popped element), but the VM RMW corrupts when the call is a **sub-expression** (e.g. `sum + arr[i].xs.remove_last()`) — `cg_declare`/`OP_GET_LOCAL` use absolute slots that assume a clean stack (`sp == phys_count`), which only holds at statement boundaries; `append`'s RMW has the same latent issue but is unreachable (unit result can't be an operand). The real fix needs VM codegen to track expression-stack depth (or handle the RMW only at clean STMT_LET/STMT_EXPR positions). Workaround: bind to a var, `remove_last`, assign back. **COST/BENEFIT VERDICT 2026-06-20 (Karl asked "what do we gain?"): full fix NOT worth it — gains NO new capability (the workaround already does it), only ergonomics + an O(1)-vs-O(n) edge on a pattern with ZERO corpus demand (0 hits in 406 .em files; the only value-returning mut-self methods are `remove_last` + one user `pop`, every call site on a local/field never an index; flare_chat designs around it on purpose). The full "expression-stack-depth tracker" introduces a language-wide codegen invariant + a silent-miscompile risk class — wildly disproportionate. DECISION: do nothing now. If a hot through-index pop ever appears, do the cheap STATEMENT-ONLY RMW (~80-100 lines, symmetric to the working `append` writeback, clean-stack-provable), not the tracker. Higher-ROI sibling: a `remove_at(i)` index-pop builtin (genuinely wanted for per-chat delete). The O(n) clone tax is from the partial-move rule, independent of OFI-072.** |
| OFI-071 | Fibers are documented as "cooperative M:N green threads" but implemented 1:1 OS-thread-per-`spawn` | **M:N SCHEDULER BUILT 2026-06-20 (gated, `make mn`)** — a worker pool (≈ncpu) multiplexing many cooperatively-yielding fibers that PARK on channels (not block their OS thread), with structured nursery join, structured cancellation, and global deadlock detection. Reuses the VM's `VM_YIELD` as the suspension point (no stackful context-switch). Verified: TSan-clean, ASan-clean, run-stage byte-identical to serial (modulo nondeterministic output ordering), `tools/mn-stress.sh` 6/6 incl. 8000 fibers in one nursery. Gated behind `EMBER_MN` (default stays cooperative N:1 / `-DEMBER_PARALLEL` stays 1:1) pending a wider soak + segmented fiber stacks (OFI-088) for the 100k tier. Truthfulness half was closed 2026-06-19. Filed OFI-086 (send-on-closed), OFI-087 (work-stealing), OFI-088 (fiber stacks). |
| OFI-070 | A struct was capped at 32 methods (`MAX_METHODS`), a fixed array — `std/flare`'s widget kit hit it | CLOSED 2026-06-18 (`StructInfo.methods` made a `grow_arena_vec` dynamic vector like `fields`; cap removed, no silent wrap) |
| OFI-069 | Glyph atlas is ASCII-only — non-ASCII text (é, —, “” …) draws as `?` | CLOSED 2026-06-18 (on-demand per-code-point glyph cache: atlas seeds ASCII, grows lazily for any code point the face has; `× ↑ … — · café` now render — pixel-verified) |
| OFI-068 | Graphics render goldens are pixel-exact, so a freetype version change shifts text metrics ±1px and fails them | OPEN (recalibrated flare.em to freetype 26.6.20; goldens should tolerate font-version drift or pin the font) |
| OFI-066 | A user function named like a width type (`f32`/`i32`/…) is unreachable — the call parses as a width conversion | CLOSED 2026-06-19 (reserved the names: `collect_signature` rejects a FREE function whose name is a `numeric_typename`, with a clear message. Locals resolve before the conversion so `let int = …` is fine, and methods `x.i32()` use other syntax — both stay legal. `tests/run/many_functions.em` renamed its incidental `f32`/`f64`; regression `error_fn_named_like_type.em`.) |
| OFI-065 | `net`, `net-graphics`, `test-parallel` were real targets but missing from `.PHONY` | CLOSED 2026-06-18 (added to `.PHONY`; found while documenting the Makefile in THE_EMBER_BOOK) |
| OFI-064 | Assigning a value-struct from a `match` case-binding to an OUTER variable double-frees (surviving OFI-062 corner) | CLOSED 2026-06-18 (clone-on-bind-out, BOTH backends; Crucible op + oracle-staleness fixed) |
| OFI-063 | `Map<K, [T]>` / arrays through erased generics double-free (arrays are unique-owner too) | CLOSED 2026-06-18 (unified deep-clone, BOTH backends) |
| OFI-062 | Value-structs through erased generics double-free (unique-owner vs refcounted-share) | CLOSED 2026-06-18 (unified deep-clone, BOTH backends) |
| OFI-056 | A function's constant pool index is one byte (max 256 constants/fn) | CLOSED 2026-06-18 (`OP_CONST_LONG`/`OP_STRING_LONG`; `tools/ceilings.sh` gates the whole narrow-operand class) |
| OFI-055 | Code-point string helpers duplicated + `text_field` lacked h-scroll | CLOSED 2026-06-18 (`cp_*` in std/string UTF-8-verified by `tools/string-diff.py`; std/ui + gui.em migrated render-identical; text_field h-scroll ported + render-tested) |
| OFI-051 | Native backend (AST→C) — M1–M5 complete; kept open as the umbrella for standing native limitations | umbrella (at planned terminus) |
| OFI-050 | Compiler symbol resolution is linear-scan | perf — deferred |
| OFI-049 | `Ptr` C handles have no lifetime tracking (double-close / leak) | **FULLY CLOSED 2026-06-19** — `Ptr` is now a LINEAR type (move-only **and** must-consume): an owned handle un-closed on any path is a compile error. Checker-only (both backends); AND-merge `consumed` dual to `moved`, erasure-proof type-formation ban, reachability flag; new **Ledger** fuzzer + a reachability false-positive fix found by it |
| OFI-046 | `?` early-return doesn't check `ensures` postconditions | CLOSED 2026-06-18 (park the propagated value in the `result` slot, then check ensures — no stack-depth tracker needed) |
| OFI-044 | Replay doesn't capture C writes into a borrowed `mut` buffer | verification edge |
| OFI-043 | FFI can't yet adopt a C-owned `malloc`'d `[u8]` buffer / transfer ownership (`char*` copy-on-return is done) | future widening |
| OFI-042 | A move-type struct can't be a `Map` key | CLOSED 2026-06-18 (dropped the `Copy` key bound — struct keys deep-clone on store via existing runtime machinery; no `Clone` interface needed) |
| OFI-020 | Channel throughput is mutex-bound for tiny messages | wontfix (poor ROI) |
| OFI-018 | Parallel cross-thread frees defer reclamation to program exit | deferred (bounded) |
| OFI-009 | Ownership safety — checker done & sound; `Copy` bound landed; only a deferred (sound) leak-until-exit in generic bodies remains | mostly done |


### OFI-122 — `Ptr` cannot be stored, so no type can own a C resource (no RAII handle/wrapper) — OPEN
*Filed 2026-06-22 from an external language review (the no-owning-wrapper consequence it flagged as the sharpest FFI gap).*

**Gap.** A `Ptr` may not be an array element, a struct field, an enum/variant field, a channel
element, or a generic type argument — the erasure-proof type-formation ban from OFI-049 (R1 in
docs/design/ptr-linearity.md; stated in docs/language.md, "Pointers, buffers, and opaque handles").
So `[Ptr]`, `Map<_,Ptr>`, `Option<Ptr>`/`Result<Ptr,E>`, `Channel<Ptr>`, and a `Ptr` struct field
are all unconstructable. The consequence the review named: you cannot build a value that **owns** a
C resource. No `struct File { handle: Ptr }`, no connection pool, no wrapper type, and no
`Option<Ptr>` for a checked open — every C handle has to live as a bare local and be closed on every
path. For a language pitching real C bindings, this is the sharpest limitation.

**Already felt.** docs/http-design.md records the concrete bite: a `Response` object "cannot simply
hold an open stream handle," so the streaming surface stays handle-passing (`open`/`next`/`close`)
until this is resolved.

**Why it exists (legitimate v1 choice).** A `Ptr` has no Ember destructor — the compiler can't know
whether to call `fclose`/`free`/`sqlite3_close` — and the linear must-consume obligation can't be
discharged once it is hidden inside an aggregate under erasure. Banning storage was the sound, minimal
fix: it subsumes the "store-into-aggregate leak" with one rule the erasure can't slip past. The
checked-open idiom today uses the null sentinel (`fopen`→null, `fclose(NULL)` a guarded no-op), not
`Option<Ptr>`.

**Fix direction.** Typed handles with a user-declared destructor (`Drop`/close) — the
"typed-handles-with-`Drop` (future) will lift the ban" already noted in ptr-linearity.md R1. A handle
type that names its own close can be stored, RAII-dropped deterministically, and still keep
leak/double-close safety. Sequencing relates to OFI-099 (the linear obligation isn't minted through a
user `fn … -> Ptr` wrapper) and OFI-043 (adopt a C-owned buffer / transfer ownership). Priority: it is
the headline gap behind the "real C bindings" claim.


### OFI-123 — The value model is width-erased: scalar widths are semantic-only, not stored at width — OPEN
*Filed 2026-06-22 from an external language review (the "real widths" caveat — true for type-checking, not yet for layout).*

**Gap.** The explicit-width numeric family (`i8…i64`, `u8…u64`, `f32`/`f64`) is real for
type-checking — range, the overflow trap, ordering, and display each take the operand's width — but
every scalar value occupies the same runtime slot regardless of width (docs/language.md, "The whole
family runs" … "the value model is otherwise still width-erased"). Two visible consequences:
(a) a `u64` **literal** can be written only up to 2⁶³−1 — larger `u64` values are reached by
arithmetic or conversion (enforced in src/parser.c: integer literals parse through signed range →
"integer literal is out of range for i64"); (b) only packed scalar **arrays** store at their width
today (`[u8]` → 1 byte/element, a struct-of-`u8` packs), while a scalar `u8` local still takes a full
value slot.

**Why it exists (deliberate).** Width-accurate native layout is a large piece of work; packed scalar
arrays + inline nested struct fields are explicitly "the first steps of native layout"
(docs/language.md). There is **no correctness risk** — range and overflow semantics are already
enforced on every operation, independent of storage width.

**Fix direction.** Width-accurate scalar storage (store/load at the declared width; native struct and
local layout), plus a `u64` literal path that admits the full unsigned range. This is the credibility
piece behind the "real widths" systems-language claim, and a large, deliberate deferral rather than a
quick fix. Relates to the native-backend layout umbrella (OFI-051).


### OFI-117 — Long-running-UI memory leak: three per-frame heap leaks made the Flare app's teardown grow with uptime — CLOSED (3 of 3 fixed) 2026-06-22
*Filed + fixed 2026-06-22, from Karl's report: "closing the Flare Claude app, the mouse spins 25s+ if it's been open a while — no error, but it feels about to."*

**Resolution.** Fixed three per-frame VM-pool leaks: (1) erased-generic borrow-arg over-retain — gate the call-site consume + temp `drop_mask` on the **parameter** type, not the argument (check.c, both free-call and method paths); closes the OFI-009 tail. (2) builtin owning-temp args — checker marks them in `drop_mask`, codegen drops after the call. (3) explicit multi-operand string `+` chains — now `consume` both operands and emit the consuming `OP_CONCAT` (dedicated `binary.str_concat` flag). Dock idle leak 0.94 → 0.24 MB/s (~75%); native already handled all three. Residual → OFI-118. (Full write-up in git history.)


### OFI-118 — a `match` scrutinee that's an owning temporary leaked on an EARLY exit from a case body — CLOSED 2026-06-22
*Filed after OFI-117; root-caused + fixed 2026-06-22 by RSS-probe bisection + a runtime object-leak counter.*

**Resolution.** A `match` whose scrutinee is a fresh owning temporary (e.g. the `Option` from `get`) released it only on the fall-through path, so a `case` body exiting early (`return`/`break`/`continue`/`?`) leaked the scrutinee once per match — Flare's per-frame `state_float` read bled one `Option`/call once the map held state. Fix (codegen.c, VM-only; native already correct): declare the match subject slot with the subject's own owning drop-flag so every early exit releases it (fall-through keeps its explicit drop; mutually exclusive, no double-free). Dock idle leak 0.24 → ~0.083 MB/s (~91% from original); regression `tests/run/match_early_exit.em`, Crucible 75/75, ASan clean. (Full write-up in git.)


### OFI-112 — Dock layout is not serialised — a workspace resets to its default on relaunch — CLOSED 2026-06-22
*Filed + CLOSED 2026-06-22.* **Resolution.** `std/flare` gained `DockTree.to_json()` + the inverse `dock_from_json()` (slot indices round-trip as-is, no re-indexing); `flare_chat` store bumped to **v4**, persisting `"dock"` alongside settings + convos and rebuilding on load — falls back to `build_workspace()` if the pinned "Chat" leaf is absent/corrupt, re-serialising the small tree only on mouse-release. Round-trip golden `tests/graphics/flare_dock_persist.em`; graphics 36/0. Next rung (separate): floating windows. (Full write-up in git.)


### OFI-071 — M:N green-thread scheduler — BUILT 2026-06-20 (gated behind `EMBER_MN`; default-flip pending soak)
*Karl (2026-06-20): "Is this not important? Should we not be sorting this out as priority? Make sure to use Crucible and write any other tools you need to make this a reality."*

**Why it matters (honest).** It does NOT speed up today's apps (the 1:1 thread-per-fiber build is already at the
~5–6× hardware ceiling). It matters because (1) founding principle #4 + the manifesto promise Go-goroutine
ergonomics — *thousands* of cheap tasks — which 1:1 pthread-per-`spawn` cannot deliver (100k spawns = 100k OS
threads); and (2) the OS-kernel endgame: a kernel has no pthreads — an M:N stackful/cooperative-fiber scheduler IS
a kernel scheduler, so this is the most kernel-relevant rung of the dogfood ladder.

**The unlock.** No `ucontext`/asm. The VM bytecode interpreter is ALREADY the cooperative yield point — a channel
op that must block sets `block_channel` and `return VM_YIELD`, and the whole fiber state lives in its `Fiber`
struct. So M:N = "run the existing cooperative scheduler on M worker threads sharing a ready-queue, parking fibers
on channels instead of blocking the OS thread." The thread-safe heap (atomic refcounts, per-context arenas,
cross-thread-free deferral) already existed from the 1:1 work.

**Design (hardened by a 5-agent adversarial workflow, then built + adversarially gated).** New `EMBER_MN` flag
(implies `EMBER_PARALLEL`). A `Scheduler` (M=ncpu workers, the calling thread is worker 0) with ONE global
mutex+condvar MPMC ready-queue of `Fiber*`. Keystone decision: **the arena lives IN the fiber** (`EmberRt rt` moved
from VM→Fiber) so a migrated fiber keeps one `home` regardless of which worker runs it — closing the cross-worker
free leak *structurally*. `ObjChannel` condvars → intrusive fiber waiter FIFOs; a blocked op parks the fiber
(`fstate` CAS = the single arbiter so a channel-wake and a cancel-sweep can't double-enqueue) — observe+register+
commit under one `ch->lock` ⇒ lost-wakeup-free. Single global lock order `channel > nursery > readyqueue > heap`
(proven acyclic). Nursery: `OP_SPAWN` pushes a fiber (no `pthread_create`); the parent parks at the closing brace
and the last child wakes it (`live` under `n->lock`, so the parent — never a child — frees the group, no UAF);
children freed at finalize so the cancel sweep can't touch freed memory. Structured cancellation: a child error
sets `n->cancel`, requeues parked siblings, they unwind at yield seams (channel ops + the OP_LOOP back-edge) via a
new `VM_CANCELLED`. Global deadlock = all workers idle + queue empty + a live fiber remains. VM-only (native stays
1:1; `runtime.c`'s native concurrency is `!EMBER_MN`).

**Verified.** `make mn` builds clean; run-stage **byte-identical to serial** (238/239; the one diff is
`nursery_spawn`'s legitimately nondeterministic output interleaving). `make tsan-mn` **clean** (no scheduler data
races) and `make asan-mn` **clean** (no UAF/double-free) across the concurrent corpus incl. 5000-fiber. New
**`tools/mn-stress.sh`** (`make mn-stress`, Crucible's sibling) **6/6**: 8000 fibers in one nursery, fan-in/out
compute, nested nurseries, deadlock (exit 65, no hang), cancel-on-error (exit 65, no hang), pipeline+close. All
existing builds/suites unchanged (default 351/0, parallel 2/2, graphics 22/22).

**Gated** behind `EMBER_MN` (Karl's call): the proven 1:1 stays the default `make parallel`; flip the default after
a wider soak + segmented fiber stacks (OFI-088). Filed OFI-086 (send-on-closed policy), OFI-087 (work-stealing),
OFI-088 (fiber stacks). Decision recorded in docs/architecture.md.


### OFI-085 — No resize/split control; panes were fixed-width — CLOSED 2026-06-20 (draggable splitter shipped + wired to the sidebar)
*Opened + closed 2026-06-20 (Karl: "we need a resize/split control adding to the language and then this should be added to the right hand side of the conversation history panel so this can be resized accordingly").*

**Resolution.** Added a first-class draggable splitter (both orientations): `std/ui._split_drag` (absolute-anchor latch — capture size + mouse-axis at press, `size = base + (axis − grab)·sign` clamped — with its own non-aliasing fields) + a tape-silent `set_cursor` builtin for the ↔/↕ pointer + `std/flare.splitter(key, size, lo, hi, vertical)`. Wired to the Claude app sidebar: `sbw` is a single persisted `state_int` (the duplicated `236` removed), window-aware max. Designed via a 3-spec judge panel + adversarial review (fixed a modal-gated-latch leak, a `w>=h` paint-orientation heuristic, a narrow-window overflow). Tests `tests/graphics/splitter.em` + `flare_splitter.em`; graphics 22/22. (Full write-up in git.)


### OFI-084 — Read-only text (code blocks) was unselectable — CLOSED 2026-06-20 (selectable code blocks shipped)
*Opened + closed 2026-06-20 (Karl, dogfooding the Flare Claude app: "we have no way to select text in the code blocks … this is a must instead of just a copy button. All major languages support this select/copy (Ctrl+C) functionality").*

**Resolution.** Wired a read-only input layer onto rendered code blocks, reusing the existing field selection/clipboard machinery: `std/ui.code_caret_at` + `pressed_down` + `_code_input` (drag-select, Ctrl/Cmd+A, Ctrl/Cmd+C; no mutation), and `std/flare._code_block`/`_paint_code` (translucent per-line highlight behind the spans). The Claude app gets it free via `f.markdown`. Regression `tests/graphics/flare_code_select.em`; graphics 20/20. Deferred: whole-document continuous selection across prose+code. (Full write-up in git.)


### OFI-083 — `.slice()` on a value-struct array reached through a struct field mis-sized its copy — CLOSED 2026-06-20 (sized the copy by the struct's `total_size` via `alloc_struct_array`; both backends, ASan-clean, Crucible 60/60; regression `tests/run/slice_value_struct.em`. The "infinite loop" was the same mis-size. Header reconciled 2026-06-22; body below is the original OPEN filing.)
*Opened 2026-06-20 (dogfooding flare_chat's `Conv.turns: [Turn]` refactor — a non-empty store froze the app at startup; `.slice()` on a value-struct array reached through a struct field mis-sized the element copy, so the `memcpy` overran the buffer — the "hang" was that corruption). Original OPEN filing (symptom / minimal repro / boundary table / fix direction) condensed 2026-06-22; full detail in git history.*


### OFI-082 — no ergonomic way to copy a value-struct OUT of an array element (wants `clone`) — CLOSED (VM); native value-struct half is a tracked follow-up
*Opened 2026-06-20 (recurred building flare_chat's conversation-delete and the text_area's `_wrap_lines`).*
*Resolved 2026-06-20 — `.clone()` shipped (VM complete; native arrays complete).*

**Symptom.** `dst.append(arr[i])` where the element is a value-struct with heap fields is a COMPILE ERROR —
*"cannot move a struct out of an array element (it would alias the array's value); read its fields in place
instead."* It is SOUND (a shallow copy-out would alias the inner heap refs → double-free) and the message
hands you the workaround (rebuild from fields: `dst.append(Conv { title: arr[i].title, msgs: arr[i].msgs.slice(0, …), … })`),
but that is verbose, easy to get wrong (forget a field), and recurs (the conversation-list rebuild, the
`VLine` merge in `_wrap_lines`). Not a bug — an ergonomic gap. Low severity (clear, guided workaround).

**Resolution — a deep `.clone()` intrinsic.** `x.clone()` returns an independent deep copy on **arrays** and
**structs** (incl. generic structs `Map<K,V>` / `Set<K>`); the receiver is READ (not consumed), so
`dst.append(arr[i].clone())` is legal exactly where the bare move-out is rejected — the copy is now *explicit*
(manifesto: costs visible). It surfaces the proven OFI-062/063 runtime keystone `own_into_slot` (clone a
unique-owner aggregate / retain a refcounted leaf, recursively), so no new memory machinery. Rejected on
scalars (assignment copies), strings/enums (immutable shared), and slices (point to `.slice(0, len)`). A
**user-defined `clone` method wins** (the intrinsic is the fallback when none exists).
- **Checker** ([src/check.c]): new `clone_op` on the GET node (1 array, 2 value-struct); array branch +
  struct-method fallback set it and return the receiver type as an owned value; receiver not consumed.
- **VM** (canonical, both `.em` apps run here): lowers to "push receiver, **OP_INCREF**" — OP_INCREF *is*
  `own_into_slot`. The OP_INCREF is **skipped when the receiver `reads_as_copy`** (an index / inline
  value-struct field already produced an owned clone via OP_INDEX, OFI-062/063), so no double-clone/leak.
- **Native** ([src/cgen_c.c]): **arrays** clone fully (always boxed Values — `own_into_slot`, or passthrough
  when the read already cloned); **value-struct** `.clone()` is a **loud compile error** for now (a value-struct
  is an unboxed `em_s` in native, and an independent owned copy is most naturally a boxed Value — the em_s↔boxed
  bridge is the deferred slice; matches the OFI-072/OFI-064 native-gap precedent — never a silent miscompile).
- **Tests/fuzz:** `tests/run/clone.em` (VM golden: struct-out-of-array, plain-local struct, array deep copy,
  nested-array element, field-of-index, Map independence); `tests/native/clone.em` (array cases, VM==binary);
  new **Crucible** `op_clone` (deep-clone a `[S]` — exercises value-struct cloning through the array path on
  BOTH backends, so it rides all 5 oracles). Verified: suite **356/0**, Crucible 150→0, ASan + double-drop
  (`emberc-trace`) clean on the headline cases + the Map.

**Remaining (native value-struct `.clone()`) — follow-up.** Lift the native em_s↔boxed gap so `s.clone()` /
`arr[i].clone()` for a value-struct compiles natively. The clean primitive is a leaf-wise `em_clone_struct`
(`own_into_slot` per flattened em_s leaf — no aliasing-box leak) for the borrow-receiver case, plus an
"unbox-move" (or a per-expression boxed-representation flag) for the reads-as-copy receiver so the boxed
`em_index` result becomes an owned em_s without a redundant clone. VM-complete already unblocks the apps
(they run on the VM); this is lockstep-completeness, not a blocker. Low priority.


### OFI-081 — `_`-prefix privacy is ASYMMETRIC: free functions are module-private, methods are not — DOCUMENTED (rule written down); principled `pub` redesign deferred to the module-system pass
*Opened 2026-06-20 (building the multi-line text_area; std/flare must call std/ui's `_ta_edit`/`_ta_draw`).*
*Resolved (part a) 2026-06-20 — rule documented in docs/language.md (Visibility §). Part b (explicit `pub`) deferred.*

**Resolution (a) — documented.** The Visibility section of [docs/language.md] now states the rule explicitly:
`_`-enforcement covers top-level **free functions, types, and constants** (reached through a `mod._name`
qualifier, which visibility can gate); a struct's **methods** with a leading `_` are a *convention/hint only*,
**not** enforced (a method belongs to its type, which travels with the value — there is no qualifier to gate),
and `std/flare`↔`std/ui` deliberately rely on `_`-methods staying callable. Behaviour re-confirmed before
writing: a cross-module `lib._hidden(5)` free-fn call is rejected; a cross-module `value._secret()` `_`-method
call compiles. So the trap (the rule was real but undocumented) is closed. **(b)** The principled fix — replace
the `_` convention with explicit `pub`/visibility, uniform for free functions AND methods — is deferred to the
module-system build-out (the kernel will want a real visibility story); not worth a rushed checker change now.

**Symptom.** A `_`-prefixed FREE function is module-private (`error: that function is private to its module
(leading '_')`), but a `_`-prefixed METHOD is callable cross-module — so `ui._wrap_lines(…)` is rejected while
`ui._ta_edit(…)` is allowed (and indeed std/flare drives std/ui's text editors through exactly such
`_`-methods). Surprising + inconsistent: `_foo` reads as "private" but only enforces for free functions — a
least-surprise miss (an LLM-first tenet).

**Assessment.** Defensible (a free function is module-scoped; a type's methods belong to the type and are
reachable wherever the type is) but UNDOCUMENTED, which is what made it a trap. Works today; not a correctness
bug; and it is load-bearing — the std/ui ↔ std/flare split relies on `_`-methods staying callable.

**Recommendation.** (a) NOW: **document the rule** (free-function `_` = enforced module-private; method `_` =
convention/hint only, not enforced) so it stops surprising. (b) LATER: when the module system is built out for
real (the kernel will want a principled visibility story), replace the `_`-convention with explicit
`pub`/visibility — one consistent model for both. Don't rush a checker change for this; it's clarity, not a
fire. Core + a semantic decision.


### OFI-074 — "value moved inside a loop body" was over-conservative for an unconditional consume-then-break — CLOSED 2026-06-20 (the loop-body move guard now tracks moved-state at the actual loop BACK-EDGES — every `continue` + a reachable fall-through, OR-accumulated — so an unconditional consume-then-break no longer trips it; both `loop` and `for`; Ledger 300/300; regressions `loop_move_break.em` + `error_loop_move_recur.em`. Reconciled OPEN→CLOSED + condensed 2026-06-22; full detail in git.)


### OFI-072 — `arr[i].append(x)` silently no-ops (method mutation through an index loses the write) — OPEN
*Opened 2026-06-19 (hit designing in-memory multi-conversation for `flare_chat.em`: an array of
`Conv` structs, each holding its own `[string]` transcript, mutated as `convos[active].msgs.append(...)`.
The appends compiled, ran without error, and **left every conversation empty**.)*

Minimal repro (`/tmp/c.em`):

```ember
fn main() -> int {
    var g: [[string]] = []
    g.append([])
    g[0].append("x")       // compiles, runs, NO error…
    g[0].append("y")
    print("{g[0].len()}")  // …prints 0, not 2
    return 0
}
```

The gradient that localises it:
- **Works** — `localStruct.field.append(x)` (receiver is a *local* place).
- **Works** — `arr[i].field = wholeArray` and `arr[i].scalar = v` (the **assignment** path resolves the
  nested place and stores back — this is what `std/layout.em` leans on: `self.nodes[i].rw = …`).
- **Broken** — `arr[i].append(x)` / `arr[i].field.append(x)` (a `mut self` **method** whose receiver is
  reached *through an index*). The indexed element is materialised into a temporary to serve as the
  receiver, `append` mutates the temporary, and the temporary is discarded — the stored element never
  changes. No diagnostic.

This is the worst failure mode: it type-checks, runs, and **silently loses data** — squarely against the
manifesto's "no silent footguns" stance. The right long-term fix is to bind a `mut self` receiver to the
underlying *place* when the receiver expression is an lvalue (index/field chain), mutating through it the
same way the assignment path already does — i.e. unify method-receiver place resolution with assignment
LHS resolution in both backends. The acceptable interim is to make it a **compile error** ("cannot call a
mutating method on a value reached through an index — assign the whole element back instead"); a no-op must
not be a runtime outcome.

**Workaround (still valid)** (`flare_chat.em` multi-conversation): the *checkout pattern* — keep the active
conversation in flat working arrays (`msgs`/`mine`, mutated freely as locals), and on every switch write
the whole arrays **back** through the index (`convos[active].msgs = msgs`, which DOES persist — assignment
path) before loading the target (`msgs = convos[active].msgs`). No mutation is ever done through an index.

**Resolution — `append` (2026-06-19).** Fixed properly in BOTH backends as a read-modify-write that reuses
the proven assignment store path (the key insight: `gen_nested_store` / the native `em_index`+`em_set_field`
+`em_set_index` sequence already write a value back through an arbitrary index/field chain with balanced
refcounts). A `place.append(x)` whose `place` reads as a copy (`expr_reads_as_copy`: rooted at an `EXPR_INDEX`,
or an inline value-struct field, or a field of either) now lowers to: read the array out of the place →
`append` into that copy in place → write the whole array back into the place. A plain local/global receiver
shares the array handle and is left on the fast in-place path. Stack ops are refcount-neutral
(`OP_GET_LOCAL`/`OP_POP` don't retain/release); ownership balances through `OP_ARRAY_APPEND`'s move-in and
the store's release-old, exactly as in `arr[i].field = v`. **Verified:** the three failing shapes now
persist (`tests/run/array_index_mutate.em` + the `tests/native/` dual-run proving VM==binary); ASan+UBSan
clean on a 30-append stress over boxed-field structs, whole-field overwrite, and nested `[[T]]`; all
value-semantics/double-free regressions (`array_struct_inline`, `generic_nested_*`, the OFI-062/063/064
suite) still pass. `src/codegen.c` (`expr_reads_as_copy` + `gen_array_append_writeback`), `src/cgen_c.c`
(`cgc_reads_as_copy` + `emit_array_append_writeback`).

**Still open — `remove_last` through a copy.** Symmetric write-back for `remove_last` has a VM stack-ordering
wrinkle (it must keep the popped element as the result while writing the shrunk array back, and there is no
neutral drop-under opcode). Rather than fix one backend and diverge, `remove_last` on a copy-reading receiver
is now a **compile error** (`src/check.c` `recv_reads_as_copy`) — loud, never silent — telling the user to
bind the array to a variable, `remove_last` from that, and assign it back. The native append-writeback also
falls back to a compile error for the rarer inline value-struct-field chains it doesn't yet emit. Finishing
both (the `remove_last` RMW and the native inline-chain case) is the remaining slice of this OFI.

### OFI-066 — A free function named like a numeric type (`i32`/`f32`/…) was silently unreachable (parsed as a width conversion) — CLOSED 2026-06-19 (`collect_signature` now rejects a free function whose name is a `numeric_typename`, with a clear message; a local `let int = …` and `x.i32()` methods stay legal; regression `error_fn_named_like_type.em`. Body condensed 2026-06-22; detail in git.)

### OFI-070 — A struct was capped at 32 methods (`MAX_METHODS` fixed array) — CLOSED 2026-06-18 (`StructInfo.methods` made a `grow_arena_vec` dynamic vector like `fields`; cap removed, no silent wrap. `MAX_METHODS` still bounds the separate `InterfaceInfo` array. Body condensed 2026-06-22; detail in git.)

### OFI-069 — Glyph atlas was ASCII-only; non-ASCII text rendered as `?` — CLOSED 2026-06-18 (per-size atlas now seeds ASCII and grows on demand via `gfx_size_ensure`, decoding the UTF-8 about to be drawn/measured and adding any code point the face has; steady state is a membership scan, so the old speed is kept; `draw_text`/`measure_text` stay in lockstep. Golden `unicode_text.em`. Body condensed 2026-06-22; detail in git.)

### OFI-065 — three real Make targets (`net`, `net-graphics`, `test-parallel`) were missing from `.PHONY` — CLOSED 2026-06-18 (added all three to `.PHONY`; robust to a same-named path appearing in the repo root. Body condensed 2026-06-22; detail in git.)

### OFI-064 — assigning a value-struct from a `match` case-binding to an OUTER variable double-freed (the bound borrow aliased the scrutinee's payload instead of copying) — CLOSED 2026-06-18 (clone-on-bind-out, BOTH backends: `consume` now sets `moves_local=2` to clone a value-struct read from a not-owned local — the value-semantics counterpart of the refcounted branch — and native mirrors the `STMT_LET` boxed→`em_s` coercion; Crucible `op_match_bind_out` added + an oracle-staleness rebuild bug fixed; regression `match_bind_clone.em`. Body condensed 2026-06-22; detail in git.)

### OFI-007/047/056 follow-up — the narrow-operand class (operand MIRROR DRIFT — each opcode's layout hand-written in opcode.h/codegen/VM/disassembler) — CLOSED 2026-06-18 (one operand spec in `include/opcode.h` drives a shared codec, gated by `make opcheck` which proves every VM handler consumes exactly the spec width; all index operands converted to LEB128 `OPK_IDX` and the `OP_*_LONG` stop-gaps retired; the checker's `MAX_*` tables (locals/funcs/structs/fields/variants) + native per-field layout made dynamically sized — all seven dimensions verified WORKS to N=2000; `make verify` gained a `parallel` `-Werror` gate. Body condensed 2026-06-22; detail in git.)

### OFI-068 — graphics render goldens are freetype-version-sensitive (text metrics shift ±1px)
*Opened 2026-06-18 (surfaced installing raylib/freetype to finish the OFI-055 UI de-dup).*

`tests/graphics/*.em` assert the EXACT rendered draw-list (op + x/y/w/h…). Widget sizes that come from
`measure_text` (button widths, and every coordinate positioned relative to them) depend on the installed
**freetype**'s glyph advances, so a freetype version bump shifts them by ~1px and the golden fails — even
though the code is unchanged. Hit when freetype 26.6.20 was freshly installed here: `flare.em` went red
(`w:39`→`w:38`, `x:59`→`x:58`, …) while the other 10 cases passed (they don't measure text). Recalibrated
`flare.em` to this machine's freetype so the suite is 11/11, but the golden will drift again on the next
freetype upgrade. **Fix (future):** make the text-measuring goldens font-version-tolerant — round/bucket
text-derived coordinates, or assert structure (op sequence, text content) not exact pixels, or ship+pin a
bundled font so metrics are reproducible. **Low priority** — a test-infra fragility, not a language/runtime
bug; the affected case is `flare.em` only.

*Update 2026-06-20 (second machine, building the Flare settings dialog).* The drift is **cross-machine, not
just cross-version**: on a different Mac whose freetype reports the *same* libtool version (26.6.20), four
text-measuring goldens drift — `flare.em`, `text_field.em`, `unicode_text.em`, `wrap.em` (e.g. button `w:38`→`39`,
a `wrap.em` line break moving by one word) — so "the affected case is flare.em only" understated it. Equal
libtool version ≠ identical advances (different patch/build, libpng/harfbuzz, or raylib font path). I did **not**
re-bless these (that would just trade Karl's calibration for mine); the new `tests/graphics/flare_modal.em`
golden was blessed here and carries the same caveat in its header. This nudges the real fix up: metric-tolerant
comparison (bucket text-derived coords / assert op-sequence + text, not exact x) or a pinned bundled font. (`f32`, `i32`, `u8`, …) is unreachable
*Opened 2026-06-18 (surfaced while lifting the `func` ceiling: the `ceilings.sh` generator named functions
`f0..f299`, and `f32()`/`f64()` parsed as width conversions, not calls).*

**Symptom.** Declaring `fn f32() -> int { … }` is accepted, but **calling** `f32()` is interpreted as the
`f32(x)` numeric width conversion (`is_numeric_typename` is consulted before user-function resolution in
`gen_expr`/the call checker), so it reports "a width conversion takes exactly one argument" and the user
function is unreachable. The same holds for `i8/i16/i32/i64/int/u8/u16/u32/u64/f32/f64`.

**Disposition.** Inconsistency, low priority — these names are de-facto reserved for conversions, but the
declaration is silently accepted rather than rejected. Two clean options: (a) reject a function declaration
whose name is a width-type keyword (fail fast at `collect_signature`), or (b) let a same-name user function
shadow the conversion at the call site. (a) is simpler and matches "a clear error beats a surprise." Worked
around in the test tool by naming generated functions `fn_$i` (no type-name collisions). Not on any path.

### OFI-063 — `Map<K, [T]>` (a map whose value is an array) returned a corrupted/empty array (arrays are unique-owner too, so sharing one through erasure double-freed it) — CLOSED 2026-06-18 (unified deep-clone `own_into_slot`/`clone_owned_else_borrow` recursing through structs AND arrays, wired at `OP_INCREF`/`OP_INDEX` (VM) + `em_index`/`em_field_owned` (native); the native generic move/alias path now `own_into_slot`s instead of a phantom `OBJ_RETAIN`. Regressions `map_array_value.em` + `generic_aggregates.em`, VM==native, Crucible 0. The first find of the Crucible fuzzer. Body condensed 2026-06-22; detail in git.)

### OFI-062 — Value-structs through erased generics double-freed (a value-struct is a unique owner, but erased generics emit `OP_INCREF`/`OBJ_RETAIN` as if it were a refcounted shareable) — CLOSED 2026-06-18 (both backends; the runtime retain-into-new-owner op now CLONES a value-struct — VM `OP_INCREF`/`OP_INDEX`, native via `own_into_slot` replacing the bare `OBJ_RETAIN`; `Map<K,struct>` works end-to-end and std/flare's rect store migrated back off its parallel-arrays workaround. Regressions `map_struct_value.em` + `generic_aggregates.em`, VM==native, Crucible 0. Body condensed 2026-06-22; detail in git.)

### OFI-056 — A function's constant pool was a single-byte index (max 256 constants/function) — CLOSED 2026-06-18 (new `OP_CONST_LONG`/`OP_STRING_LONG` 3-byte index emitted only past 255, so the common case stays one byte and no golden shifts; cap 256→16,777,215, beyond is a clean error. Also added `tools/ceilings.sh`/`make ceilings` to gate the whole narrow-operand class — which surfaced + guarded silent >64 field/variant truncations. Later superseded by the OFI-007/047/056 LEB128 rework. Body condensed 2026-06-22; detail in git.)

### OFI-055 — Code-point string helpers were duplicated (gui.em + std/ui) + `text_field` lacked h-scroll — CLOSED 2026-06-18 (canonical `cp_*` family added to `std/string`, UTF-8-verified against CPython by `tools/string-diff.py` over 10k+ fuzzed cases; std/ui + gui.em de-duped to it render-identical (flare draw-list md5 unchanged); `text_field` gained `clip`-masked horizontal scroll that keeps the caret in view. Regressions `string_codepoints.em` + `text_field.em`. Body condensed 2026-06-22; detail in git.)

### OFI-051 — Native backend (AST→C): M1–M5 complete (umbrella for standing native limitations)
*Opened 2026-06-16 (while building the native backend — step 1 of the OS-capability ladder).*
*Status 2026-06-17: M1–M5 complete; kept open as the umbrella for the standing by-design limitations.*

The native backend (`emberc --emit=c` / `emberc -o`, docs/architecture.md "Decision: a native backend
that lowers the AST to C") is **M1–M5 COMPLETE**: it compiles **everything the VM accepts** to a
standalone binary, validated against the VM by the `tests/native/` differential suite. Shipped across
the campaign: scalars + the full width-aware operator set; all aggregates (structs as real C value
types, enums + match, arrays, strings); erased generics + Option/Result + `?`; closures (lambdas,
captures, function values, generic HOFs); `dyn` interfaces; bounded generics → Map/Set; a full
drop-discipline pass (leak-free, RSS-verified); concurrency (spawn/nursery/typed channels on real
threads + the ported deadlock detector, conditional parallel build); and M5 — numeric conversions,
native builtins (libm math, file/stdin I/O, `args`/`env`/`exit`, `clock`, `len`, `assert`, wrapping
arith), string/array methods, and the `extern "c"` FFI. **Standing native limitations (by design, not
bugs):** contracts are not enforced in native output (verification stays a VM capability), and `make
install` doesn't yet ship the runtime headers, so `emberc -o` resolves `ember_rt.h` relative to the
build tree. **Kept open as the umbrella; campaign at its planned terminus.** The milestone record
follows (M2a … M5; residual edge cases are closed under OFI-054):
- **M2a** — DONE: the object runtime is extracted from `src/vm.c` into `src/runtime.c` behind an
  `EmberRt` context (object list + recycle pool + struct-layout table), shared by the VM (which embeds
  `EmberRt rt` and calls `&vm->rt`) and, ahead, by generated C. Packed marshalling
  (`value_box`/`value_unbox`/`array_box`/`elem_size_for`) is inline in `include/ember_rt.h`. Verified
  zero-behavior-change (serial + parallel suites green). `src/runtime.c` does not reference dispatch,
  the `CompiledProgram`, or verification state, so it links into a bare binary.
- **M2b** — STRUCTS DONE (construct + field read): the C emitter emits an `em_struct(...)`
  constructor (declared-order field packing) and `em_get_field` / `em_get_field_owned` reads, plus a
  baked-in `StructType` table + a process-wide `EmberRt g_em` context and the `libember_rt.a` link
  (`build/libember_rt.a`, located next to `emberc`). Ownership for a field read is derived from the
  object's shape (a named binding borrows; a fresh temporary drops — the checker's `drop_object` is
  unreliable under the boxed model). Drop discipline emits `drop_value` at scope/return/block/loop-body
  exits. Covers scalar + nested (inline) structs, borrow-pass, return-by-move; differential-tested
  (tests/native/struct*.em). Representation is ALWAYS BOXED — multi-slot hints ignored.
- **M2b** — struct field ASSIGNMENT DONE: `o.f = v` via `em_set_field` (drops the old boxed field,
  mirrors OP_SET_FIELD); reassigning an owned `var` drops the previous value first. Nested inline-struct
  write-back (`line.a.x = v`) deferred. (Fixed a Makefile bug along the way: `RT_LIB` was defined after
  the `all` rule, so `$(RT_LIB)` expanded empty in its prerequisites and the runtime lib never rebuilt
  on a `runtime.c` change — now defined before `all`.)
- **M2c** — METHOD CALLS DONE: a struct method call `recv.m(args)` threads the receiver as self (arg 0)
  via the method's `field_index` slot; struct args pass by value; module-qualified `mod.foo` falls through
  to the direct path. Deferred: temporary receivers (`mk().m()`), and bound/dynamic/array-string intrinsic
  dispatch (generics/interfaces/arrays/strings).
- **M2 STRUCTS — RESHAPED to real C structs (DONE).** The boxed-`Value` representation double-freed on
  struct MOVES (`let q = p`, move-params: two aliases free one heap object). Fixed by lowering value-type
  structs to real C structs (`typedef struct { Value f0; … } em_s<sid>;`) — construction is a compound
  literal, fields are `.f<idx>`, value semantics (moves/copies/nesting) come from C, no heap, no drop;
  `mut self` is passed by pointer. (Docs: architecture.md "Decision: value-type structs lower to real C
  structs".) "Copy structs" turned out MOOT — structs are NEVER `Copy` in Ember (only scalars/strings/
  enums/closures), so a struct copy is always a move. The 4 boxed struct helpers were removed.
- **M2d — ENUMS + MATCH DONE.** Enums are BOXED (heap, refcounted) in the C backend — unlike value
  structs — because the VM boxes them too, so the checker's move/drop/refcount flags ALIGN with the
  representation. Construction is `em_enum(ctx, enum_id, variant, n, …)` (zero-field `Red` and payload
  `Circle(2.0)`); `match` lowers to a C `switch` on `em_tag` with positional field bindings (borrows via
  `em_enum_field`), `case _` → `default`, `subject_drop` for a temp scrutinee. Refcounting is correct
  (`moves_local==2` → `OBJ_RETAIN` on a shared alias; consuming params release; verified by a 100k-iter
  match loop, no leak/double-free). First slice = **non-generic** enums with scalar/value payloads.
- **M2e — ARRAYS DONE (scalar element).** Arrays are BOXED heap MOVE types (like enums but unique-owner,
  not refcounted) — the checker's flags align with the boxed rep, and moves use the existing move-nil /
  drop machinery. Literal `[1,2,3]` → `em_array(ctx, n, elem_kind, …)`; `arr[i]` → `em_index` (bounds-
  checked); `arr[i] = v` → `em_set_index`; `arr.len()`/`arr.append(x)` → inline/runtime; `for x in arr`
  → a C index loop binding each element as a borrow (a temp array literal/call result is dropped after).
  Drop frees the buffer + elements; verified by a 50k-array loop (no leak/double-free). Deferred: slices
  (`arr[lo..hi]`), `remove_last`/pop, arrays of structs/arrays (boxed/inline-struct elements), indexed
  `for (i, x)`.
- **M2f — STRINGS DONE (boxed, refcounted, immutable).** Literals → `em_str(ctx, bytes, len)`
  (`make_string`-backed, interning deferred — value-equality is unaffected); concatenation `+` →
  `em_add(ctx, a, b, nk)` (string branch allocates a fresh result); interpolation `"x = {e}"` folds
  parts left with `em_add`, each hole rendered by `em_to_string(ctx, v, render_kind)` (`%lld`/`%llu`/
  `%g`); `==`/`!=` compare bytes (`em_value_eq` memcmp branch); `.len()` → inline byte length; `print`/
  `println` → `em_print`/`em_println`. **Drop discipline (the crux, learned here): neither `em_add` nor
  `em_print` consumes its operands** — the VM's `OP_ADD` and `print_value` only READ, never drop; a
  named/var operand is freed by the checker's scope drop and a literal/temp operand by the exit sweep
  (`rt_free_objects`), exactly as in the VM. My first cut had both helpers drop their operands, which
  double-freed a string param (`em_add` drops it, then the param's scope-exit drops it again → abort) and
  use-after-freed a reused binding (`println(msg)` freed `msg` before `msg.len()`). Differential-tested
  (tests/native/string.em + string_loop.em), incl. a 20k-iter concat/interpolation loop and an aliased
  binding (retain/release balance). **KNOWN GAP (shared with enum/array temp ARGUMENTS): owned temporary
  call arguments leak until the exit sweep** — the C backend doesn't yet implement the checker's
  `drop_mask`/`release_temp` so a per-iteration temp argument accumulates (bounded by iteration count,
  all reclaimed at exit; matches VM output but grows peak memory in a long-running loop). Implementing
  the call-site temp-drop discipline is the proper fix → a follow-on milestone. Deferred string methods:
  `.chars()`/`.bytes()`/`.split()`/`.char_count()`/`.parse_int()`. Also still deferred: generic enums
  (Option/Result → M3 generics), recursive / heap-payload enum variants, the `?` operator. `make install`
  of headers + the `.a` still pending (emberc -o works from the build tree today).
- **M3a — UNBOUNDED GENERICS + Option/Result + the `?` operator DONE.** Generics are ERASED: a generic
  function lowers to exactly ONE C function over the uniform boxed `Value` — no per-type specialization,
  no monomorphization machinery ported. The emitter just stops rejecting generic functions/calls and
  routes every instantiation's call to that one base slot via the call's `resolved_fn` (the monomorphizer's
  appended instance slots are collapsed away — byte-identical bodies). Option/Result are the boxed enums
  the backend already builds (`em_enum`/`em_enum_field`/`em_tag`). The `?` operator (EXPR_TRY): a GCC/clang
  statement-expression that on the success variant MOVES the payload out (field 0, retained) and frees the
  shell, and on Err/None runs the function's owning-local drops and `return`s early (the early `return`
  legally exits the enclosing C function from expression position; a `?`-bearing function always returns a
  boxed enum = `Value`). Differential-tested incl. 40k-iter stress of BOTH `?` paths over heap (string)
  payloads with owning locals (no leak/double-free). **GAP (clean-errored, not miscompiled): a generic
  instantiated over a value-type STRUCT** — the erased body is over boxed `Value` but a value struct is a
  real C `em_s<sid>`, so the types collide; needs the struct↔box bridge (slice 3d). Guarded precisely:
  reject only when a value-struct flows into an erased `Value` type-parameter or return, not a concrete
  struct param. tests/native/generics.em.
- **M3b — CLOSURES DONE (lambdas, captures, function values, higher-order calls).** A closure is the boxed
  `ObjClosure` the VM uses (refcounted; rides the existing `Value` lane, so the checker's move/drop flags
  already align). New runtime: `em_closure(ctx, fn_index, capture_count, …)` (builds the ObjClosure,
  retains heap captures) and `rt_call_closure(ctx, clo, argc, args, invoke)` (lays out `[captures…, args…]`
  and dispatches via a function-pointer `invoke`, retaining captures AND args — the erased-T runtime retain
  that keeps HOF calls sound). The emitter reads captures by NAME from the lifted function's leading params
  (the checker names them after the enclosing locals — no AST change needed), and generates a uniform
  `em_invoke(ctx, fn_index, slots)` trampoline: a `switch` over every all-`Value`-signature function (lifted
  lambdas + bare function values) calling the concrete `em_fn_<k>(slots[0]…)`. `em_invoke` is emitted
  non-static so a closure-free program (which never references it) doesn't trip `-Wunused-function`.
  Generic HOFs compose (3a+3b): `std/list` `map`/`filter`/`reduce` over arrays with lambdas run natively.
  Differential-tested incl. 20k-iter stress with heap captures, inline-lambda temporaries, and per-iteration
  lambdas (refcount-balanced, no crash). tests/native/closures.em. **GAP: a closure/function value with a
  value-struct in its signature** is not yet boxable (same struct↔box bridge as 3d); `em_invoke` only covers
  all-`Value` signatures.
- **M3d — `dyn` INTERFACES DONE.** A struct is UPCAST to an interface value (the checker's `coerce_witness`
  on a value site, wrapped in `emit_expr`): box the receiver (`em_box_struct`) and bundle it with a vtable
  (an `em_enum` record of the impl's method fn-indices) via `alloc_interface`. A `dyn_method` call reads
  `vtable[slot]`'s fn-index and dispatches through a generated `em_invoke(ctx, fn_index, slots)` trampoline
  (one `switch` over every function, UNBOXING struct receivers/args via `em_unbox_struct` and BOXING struct
  returns). Heterogeneous `[Shape]` + per-element dispatch work; 20k-iter stress matches. tests/native/
  interfaces.em.
- **M3c — BOUNDED GENERICS DONE.** Witnesses are dictionary-passed: a bounded free function (`max<T: Ord>`)
  takes them as hidden leading `Value w0..` parameters (`fn_witness_count`); a bounded generic STRUCT
  (`Map`/`Set`) stores them as trailing struct fields, appended at construction (`emit_struct_lit`). A bound
  method call reads the method fn-index from the witness (`w<n>` or `self.f<n>`) and dispatches via
  `rt_call_indirect` — a built-in key's Hash/Eq (index ≥ `WITNESS_NATIVE_BASE`) routes to a native shim
  (`em_hash_any` / `em_value_eq`), a user method to `em_invoke`. `max<Version>`, `Set<int>`/`Set<string>`,
  and `Map<K,V>` all run native (differential + 3000-round build/drop stress). tests/native/bounded.em +
  collections.em.
- **THE VALUE-STRUCT↔BOXED BRIDGE (the shared core of M3c/M3d, also closing "arrays of structs").** A flat
  value struct (`em_s<sid>`, no nested-inline-struct field) is a contiguous `Value[]`; `em_box_struct` packs
  it to a heap `ObjStruct` (retaining heap fields) and `em_unbox_struct` reads it back. Applied at: interface
  upcast, generic-over-struct args/returns (`emit_generic_call` boxes a struct arg, unboxes a struct return —
  the erased `-> T` return sid resolved through `mono_args`, a struct SemType being its own sid), and struct
  payloads ENTERING boxed containers (`emit_value_arg` for enum/array construction + append) and LEAVING them
  (`emit_field_get` reads a boxed struct's field via `em_enum_field`). Generic struct INSTANCES alias to their
  BASE struct's C typedef (instance→`base_id`, flat only) so one erased method type-checks across instances —
  keeping distinct generics apart even when layouts coincide (Set and Map are both four Value fields).
- **M3 KNOWN GAPS (clean errors / honest frontier, not miscompiles):** generics/interfaces/containers over
  NON-FLAT structs (nested inline-struct fields) — the bridge assumes flat; `mut self` DYNAMIC/bound dispatch
  (em_invoke skips a mut-self pointer signature); a generic interface/method call form that isn't a direct
  free call. Still genuinely deferred: FFI + native builtins like `args()` (M5 — blocks
  examples/15_wordcount.em), most string/array methods, slices.
- **M4 — CONCURRENCY DONE (spawn / nursery / typed channels on real OS threads).** A spawned task runs
  `em_invoke(fn, args)` on its own pthread with a PRIVATE thread-local context (`_Thread_local g_em` —
  lock-free same-thread alloc; shared values are atomic-refcounted); a `nursery` collects spawns into a
  heap task list and `em_run_nursery` launches one thread per task and joins. Channels are the runtime's
  `ObjChannel` (pthread mutex + dual condvars): `em_channel_new/send/recv/close`, with recv building an
  `Option<T>` (Some/None on closed+drained). The VM's per-nursery DEADLOCK DETECTOR is ported
  (`em_nursery_park` — a fully-blocked group prints once and `exit(70)`s rather than hanging). A finished
  worker merges its arena into a shared graveyard (`em_merge`, one lock per worker); cross-thread frees
  defer via `Obj.home`; main's exit sweep frees the graveyard. **Conditional build:** `emberc` detects
  concurrency (a spawn/nursery anywhere) and only then compiles the generated C with `-DEMBER_PARALLEL`
  `-lpthread` against a parallel runtime variant (`libember_rt_par.a`) — serial native binaries keep their
  non-atomic, pthread-free representation. Verified: a 4-worker job pool (deterministic sum, 20/20 no
  races, differential-matched), a 10k-job pool (bounded RSS), strings handed off cross-thread (bounded RSS
  — merge + deferral sound), and the deadlock detector. tests/native/concurrency.em. **Fixed along the way
  (latent, pre-existing):** a `match` lowered to a C `switch`, so an Ember `break` in a case (the
  `loop { match recv(c) { case None { break } } }` channel-drain idiom) broke the *switch*, not the loop →
  infinite loop. `match` now lowers to an if/else-if chain. **Deferred (clean error):** spawn of a
  method/closure or a bounded-generic function; `05_concurrency.em` additionally needs string methods
  (`str.contains`).
- **M5** — FFI (`extern "c"`), and `print`/`println`/math/conversion builtins.

Also: **contracts (`requires`/`ensures`) are not enforced** in native output (treated like a
`--release` build for now — verification stays a VM/debug capability, the determinism north star), and
**`make install` doesn't yet ship the runtime headers**, so `emberc -o` finds `ember_rt.h`/`value.h`
relative to the compiler's build tree (`<bin>/../include`) rather than an installed location. These are
**planned milestones / known gaps**, not defects.

### OFI-050 — Compiler symbol resolution is linear-scan (perf, deferred)
*Opened 2026-06-16 (whole-codebase review, performance angle — measured, not a current bottleneck).*

The checker resolves names by scanning tables: `resolve_signature` strcmp-walks every function on
each call-site check, and `resolve_struct`/`resolve_enum`/`resolve_variant`/`resolve_method` do the
same per node; codegen's `mono_resolve` linearly scans the whole-program monomorphization table at
every generic call site. Asymptotically O(N·M) / O(G²) in functions × call sites. **Measured: not a
problem at current scale** — function/struct tables are capped at 256 (`MAX_FNS`/`MAX_STRUCTS`), and a
generated 250-function × 1000-call program type-checks+codegens in ~4 ms. **Fix when it matters:** build
a per-module name→index hash once after collection (the tables are frozen before bodies are checked),
turning each resolve into O(1); stamp the resolved instance onto the call `Expr` during planning so
codegen reads it directly. Cheaper companions, similarly deferred: json.c grows `items`/`keys`/`vals`
by one element per `realloc` (O(K²) — give it amortized doubling like chunk.c), and the VM's hot
dispatch loop re-tests `tracer != NULL` every instruction (predictable branch; templating the loop
would remove it). **Premature to do now** — refactor risk with no measurable gain; revisit if compile
times grow.

### OFI-049 — `Ptr` C handles had no lifetime tracking (double-close / leak) — FULLY CLOSED 2026-06-19 (`Ptr` is now a LINEAR type — move-only AND must-consume: an owned handle un-closed on any path is a compile error. Checker-only, both backends: `is_move_type(TY_PTR)` + extern `move`-param gate (double-close half, 2026-06-18); then a `consumed` AND-merge dual to `moved`, a shared leak scan at every exit (return/break/continue/`?`/discard/`var`-reassign), the loop-exit merge for the close-on-break idiom, an erasure-proof type-formation ban (no `[Ptr]`/`Option<Ptr>`/`Map<_,Ptr>`/struct field — the root of OFI-122), a borrow-launder guard, and a reachability flag. New **Ledger** fuzzer 600/0 (0 unsound, 0 over-strict); ASan-clean, VM==native. The N-handle `defer`/`with` cleanup is deferred. Closes the whole-codebase FFI-safety line M9. Body condensed 2026-06-22; full detail in git + docs/design/ptr-linearity.md.)

### OFI-046 — `?` (try) early-return didn't check `ensures` postconditions (it emitted a bare `OP_RETURN`) — CLOSED 2026-06-18 (on the `?` failure path, park the propagated value into the `result` slot with one `OP_SET_LOCAL phys_count`, then run `emit_ensures_checks` — no stack-depth tracker needed; guarded so the multi-slot-return case never coincides. Regressions `error_ensures_try.em` + `ensures_try.em`, VM==native. Residual (separate): owning temporaries abandoned below the value on a mid-expression `?` still leak. Body condensed 2026-06-22; detail in git.)

### OFI-044 — Record-replay doesn't capture C side effects on a borrowed `mut` buffer
*Opened 2026-06-15 (surfaced running `--emit=replay` on the new FFI showcase — examples/16_ffi.em).*

Deterministic record-replay (§5j) captures each foreign call's **scalar result leaves** and, on
replay, returns them while skipping the real C call (its effects don't recur). That is exactly right
for a value-returning call (`sin`, `strlen`) — but a C function that writes into a borrowed `mut`
buffer (`fread`, `memcpy`-style) has a second output channel: the **bytes it wrote into the Ember
array**. Replay records the return count but not those bytes, and since it skips the real call the
buffer is never filled — so a program that reads a file into a `[u8]` and then *uses* the bytes
diverges on replay (`{"status":"diverged"}`). This is replay being **sound** — it surfaces that an
effect wasn't captured rather than silently producing a wrong "reproduced" run — but it means
buffer-reading FFI programs aren't replayable yet. Scalar/handle-only FFI replays fine (see
`tests/replay/ffi.em`, libm). **Fix (future):** in record mode, after a call with a `mut` buffer arg,
snapshot the buffer's post-call bytes into the nondet log; in replay, restore them after returning the
recorded result. The wrapper already knows which leaves are `'b'` buffers and `mut`, so the metadata
is in hand. **Not urgent** — it's a replay-coverage gap for one FFI shape, and it fails safe.

### OFI-043 — The C FFI can't yet adopt a C-owned `malloc`'d buffer / transfer ownership (`char*` copy-on-return is done)
*Opened 2026-06-15 (deliberate scope cut while shipping the pointer/buffer FFI — §5h pointers).*

The pointer/buffer FFI lets C *receive* Ember heap values as borrowed pointers — a `string` as a
`const char*`, a packed `[u8]` as a buffer (`mut` if written), a `Ptr` as an opaque handle — and
that is enough to bind real C (libc file I/O, string functions; see `examples/16_ffi.em`). What it
does **not** yet handle is the other direction: a C function that *returns* memory it owns — a
`char*` from `strdup`/`getenv`-style APIs, or a freshly-`malloc`'d buffer. Ember would have to either
**copy** the bytes into a fresh `string`/array on return (and let C keep/free its copy) or **adopt**
the pointer and free it later — both need an explicit ownership rule at the boundary, and getting it
wrong leaks or double-frees. The borrow model (Ember owns nothing C owns) was the sound, simple first
cut. **Fix (future):** annotate a returned `char*` as copy-on-return (the safe default — wrapper does
`strdup`-then-Ember-copy, C frees its own), with an opt-in "Ember adopts + frees" form for APIs that
transfer ownership. Until then, a C function that returns owned memory must be wrapped to write into a
caller-provided `mut [u8]` buffer instead (the `fread` pattern). **Not urgent** — the buffer-out
pattern covers most real APIs.

*Update 2026-06-17 — copy-on-return for returned `char*` is now IMPLEMENTED (the string half of this
OFI).* `CExternSig` grew a `ret_is_string` flag: when set, the wrapper returns a `malloc`'d `char*`,
and the FFI marshalling (both `OP_CALL_C` in `src/vm.c` and `em_ffi` in `src/runtime.c`) copies it
into an owned Ember `string` and `free`s the C buffer — the safe copy-on-return default, no adopt. The
`http_post` libcurl wrapper (`src/cextern.c`, `#if EMBER_NET`) uses it to hand a whole HTTPS response
body back to Ember as a string; this is what powers `public/claude-desktop` (Ember ↔ Anthropic
API). **Still open:** (1) copy-on-return for a non-string `malloc`'d *buffer* (`[u8]`) — same mechanism,
needs a length channel since there's no NUL terminator; (2) the opt-in "Ember adopts + frees the raw
pointer" form for true ownership-transfer APIs. Kept Open for those two; the common `char*`-returning
case is done.

### OFI-042 — A move-type struct couldn't be a `Map` key (the `Copy` key bound excluded it) — CLOSED 2026-06-18 (dropped the `Copy` bound → `Map<K: Hash + Eq, V>`; a struct key is deep-cloned structurally on store via the existing `own_into_slot`/`clone_owned_else_borrow`, so the map owns its copy — value-semantic keys, no `Clone` interface or `clone()` ceremony. Regression `struct_keys.em`, VM==native, ASan-clean, Crucible 0. Body condensed 2026-06-22; detail in git.)

### OFI-020 — Channel throughput is mutex-bound: high-frequency tiny messages don't parallelize
*Opened 2026-06-12 (parallel benchmark `pipe` section).*

The parallel channel ([include/value.h](include/value.h) `ObjChannel`, [src/vm.c](src/vm.c)
`OP_SEND`/`OP_RECV`) guards its circular buffer with one `pthread_mutex`. Every send and every
recv takes that lock, so a workload that pushes a huge number of *trivial* messages through one
channel is dominated by lock contention: the `pipe` benchmark (16 producers → 1 channel → 1
collector, `s.len()` per message) runs **~25–50× SLOWER under the parallel runtime than under
the serial cooperative one**. **Proven to be mutex contention, not wake-up strategy:** time
scales with the number of contending threads at fixed total work (1 producer 233ms → 16
producers 1409ms) and is **insensitive to channel capacity** (cap 16 → 8192 barely moves it),
which rules out sleep/wake cycles. **PARTLY ADDRESSED 2026-06-13:** (a) two-condvar split
(`not_empty`/`not_full` + targeted `signal`) — correct bounded-buffer design, helps multi-
*consumer* fan-out; (b) **waiter-gated signalling** — `recv_waiters`/`send_waiters` counts
(under the channel mutex) so a send/recv only fires a condvar signal when a peer is actually
parked. **(b) is a real 2× win on uncontended/low-contention channel throughput** (1-producer
pipe 233ms → 109ms — the consumer keeps up, so producers skip the needless wakeups) and helps
moderate contention (8 producers 729ms → 571ms). **Neither fixes the SATURATED many-producer
case** (16 producers 1409ms → 1352ms): there the bare **mutex acquisition** (every op locks,
17 threads contend) is the cost, and gating the signal can't remove it.

**Remaining fix = lock-free, and the honest ROI is poor — recommend NOT building it now.**
Only a lock-free MPMC ring (Vyukov bounded: per-cell sequence numbers, producers/consumers CAS
their own position counter; mutex+condvars retained only for the rare blocking-wait, so the
deadlock detector + serial path stay untouched) removes the producer contention. BUT measured
ceiling: even with ZERO contention a parallel channel op is ~9× serial's cost (1-producer
0.34µs/msg vs serial 0.084µs/msg) — that gap is **cross-core cache coherence** (each message's
cache line migrates producer-core → consumer-core), which no lock-free design removes. So
lock-free would take the 16-producer pipe ~1350ms → an estimated ~300ms (big relative win) but
it would **still be slower than serial** (27ms) for this tiny-message case, and a single
consumer is an inherent Amdahl bottleneck regardless. Against that: every REALISTIC pattern
already scales — compute/alloc/nested ~5–6×, and the same pipe with real per-message work hits
1.7× (200 iters) to 5.1× (1000 iters). **Verdict:** high risk (the hardest concurrency change)
for a pathological, non-idiomatic case that stays a loss; leave the Vyukov design recorded here
and revisit only if a genuinely channel-throughput-bound workload appears. See `make parbench`.

### OFI-018 — Parallel cross-thread frees defer reclamation to program exit (bounded growth)
*Opened 2026-06-12 (M:N parallelism Stage 4 — per-worker pools).*

To make same-thread allocation lock-free, each worker VM owns a private object list +
recycling pool and an object is tagged with its `home` VM ([src/vm.c](src/vm.c) `reclaim`).
A same-thread free reclaims immediately (no lock); a **cross-thread** free — a heap value
moved to another worker through a channel and dropped there — cannot touch the allocating
worker's arena, so it is **deferred**: the dead object is left linked on its home list and
freed by the exit sweep when that worker merges its arena into the shared heap. This is
correct (freed exactly once, no double-free — `home` is compared for identity only, never
dereferenced) and the common case is fully lock-free, but channel-passed objects are **not
recycled mid-run**, so a long-running, channel-heavy parallel program shows bounded memory
growth until the nursery ends (then the worker merges and the next sweep reclaims). For
batch programs (the compiler's workload) this is a non-issue. (The 2026-06-13 channel-refcount fix
follows this same rule: a `Channel<T>`'s **home** thread reclaims it immediately on the last drop,
while a non-home last release still defers to the exit sweep — the only residual channel deferral.)
**Fix (if a long-lived
channel-heavy workload ever needs it):** a lock-free remote-free queue — a cross-thread free
pushes the object onto its home arena's MPSC stack (atomic CAS), and the home worker drains
that stack into its pool at its next allocation. Deferred deliberately: the defer-to-exit
model removed the real bottleneck (alloc-heavy parallel went from 5.5× *slower* than serial
to 3.6× faster) at a fraction of the complexity and corruption risk of remote-free queues.

### OFI-009 — Ownership *safety* analysis (move-tracking, aliasing, inferred return lifetimes)
*Opened 2026-06-10 (field-mutation slice); **core landed** 2026-06-10 (ownership slice).*

**Largely resolved.** A sound, function-local ownership analysis now runs:
- **Move-tracking / use-after-move** — heap aggregates (structs, generic struct instances) are
  *move* types; `let q = p`, a struct/variant field, a `move` argument, or a return transfers the
  value and marks the source moved; using a moved binding is an error. Scalars/strings/enums copy.
  Reassigning a `var` revives it.
- **No aliased mutation** — the move on `let q = p` closes the hazard that opened this OFI.
- **No escaping borrows** — returning a borrowed parameter is rejected (take it `move`).
- **Borrow conflicts** — the same value can't go to a `mut`/`move` parameter and be aliased by
  another argument in one call.
- **Control flow** — `if`/`match` arms merge move-state soundly (same value may move on different
  arms); moving inside a loop body is rejected; partial moves (a field out of a struct) are
  rejected. Implemented in [src/check.c](src/check.c) (`consume`, `is_move_type`, the
  snapshot/merge helpers, `Local.{owned,moved}`); verified by `tests/run/ownership_*` and the
  `error_*move*`/`error_escape_borrow`/`error_borrow_conflict` cases.

**Remaining tail — RESCOPED 2026-06-10** (the original framing over-stated the difficulty):

1. **Inferred return lifetimes — essentially MOOT for Ember, dropped as a goal.** Lifetime
   inference only matters when a function can *return a borrow* (a reference into its input that
   the caller keeps using, e.g. Rust's `fn first(xs: &[T]) -> &T`). Ember has **no first-class
   references** — no `&T` type, a borrow can't be stored or returned. *Every* return is by value:
   owned/constructed, or ownership **transferred via explicit `move`**. And explicit `move` for
   transfer is exactly what MANIFESTO §5b mandates ("the dangerous direction must be typed
   explicitly"). So `fn max<T: Ord>(move a, move b) -> T` is the *correct* signature, not a
   missing-inference workaround — there is no return-borrow case to infer for. (Holds as long as
   Ember stays reference-free, which the LLM-first "no lifetime syntax" goal wants.) The "genuinely
   hard, research-grade" worry was misplaced.

2. **Generic-body ownership — the soundness hole is CLOSED 2026-06-13 (Stage 1).** It was worse
   than "narrow": a type parameter was treated as *non-move*, so a generic body aliasing a `T`
   value (`fn twice<T>(t){ let a=t; let b=t }`) double-owned and **double-freed a struct argument
   at runtime — a SIGTRAP, real memory unsafety**, exactly the class the checker exists to prevent.
   **Fix:** `is_move_type` now returns true for a type parameter, so generic bodies are ownership-
   checked (returning a borrowed `T` is an escape error — take it `move`); and `consume` now MOVES
   an *owned* type-parameter local instead of incref-sharing it (a struct can't be double-owned; a
   refcounted `T` transfers its one ref soundly) while a *borrowed* `T` and field/element reads keep
   the incref-share path (the `var acc = init` accumulator over a borrowed `U` needs it). A generic
   that returns its argument now takes it `move` — the stdlib HOFs were already linear and unaffected
   (`std/list`/`std/map` green); only 4 tests + the `identity`/`max` demos needed `move`/no-reuse.
   Regression test `tests/run/error_generic_use_after_move.em` (the old SIGTRAP is now a teacher-grade
   `use of 't' after it was moved`). 206 green, parallel 159, examples 7. **The `T: Copy` bound is now
   DONE** (MANIFESTO §5f): `fn identity<T: Copy>(x: T) -> T` may alias/return `T` by copy without `move`;
   `Copy` is a contextual marker (no keyword), composes (`T: Ord + Copy`), and a non-copyable argument for
   a `Copy` param is a clean error. Ember-native: `Copy` = everything except struct/array (shareables are
   immutable + refcounted → copy = a cheap incref). Wired in parser.c (`is_copy`), check.c (`is_copy_param`,
   call-site enforcement, move-exemption); tests `tests/run/generic_copy.em`, `struct_return_copy_param.em`,
   `error_copy_struct.em`. So the ownership tail is fully resolved.

3. **Deterministic drop/free** — the "memory-safety *without a GC*" payoff. **In progress
   2026-06-10** (now that concurrency makes long-running programs real). Landed: **structs** are
   unique owners freed at scope exit (`OP_DROP`, recursive into struct fields, O(1) reclaim via a
   doubly-linked object list); **conditional moves** handled by nilling a slot when its struct is
   moved out, so a scope-exit drop is a no-op on the moved path (no static drop-flag pass needed);
   **strings, arrays, and enums** are shared and **reference-counted** (`OP_INCREF` on aliasing a
   live value, refcount dropped at scope exit / when a containing struct/array/enum is freed,
   recursively releasing elements and payloads). Values flow correctly **through channels** (`send`
   records the channel's reference, `recv` transfers it to the receiver); **unbound temporaries**
   are released (a `match` scrutinee like `recv(ch)` is dropped at match end via `OP_DROP` on the
   subject slot; a discarded expression-statement result via `OP_RELEASE`); and **call arguments**
   are reclaimed by the callee — a refcounted parameter is released on return (the call site
   increfs an aliased argument and adopts a temporary; `Param.release_at_exit`), and a `move`
   struct parameter is freed when the call returns. Since structs are unique and shareables are
   immutable, **no reference cycles can form**, so counting is complete. **Abandoned-channel
   reclamation is now CLOSED 2026-06-13** — `Channel<T>` is a refcounted shareable type, reclaimed at
   the last drop instead of leaking to the exit sweep (see docs/architecture.md "Channel<T> is a
   refcounted shareable type"). *Deferred (sound — leak-until-exit):* only refcounted values flowing
   through a **generic** body (erased `T`, so the callee can't release — tied to the generic-ownership
   gap above). The discipline is **mutable aggregates = unique ownership; immutable shareables =
   refcount.** See [docs/language.md] "Memory model".

Net: the ownership *checker* is done and sound; deterministic GC-free reclamation now covers
structs, strings, arrays, enums, channel-borne values (including a channel's own refcounted
reclamation at the last drop), discarded temporaries, and call arguments — the only remaining leak
is the (sound, leak-until-exit) generic-body case.


## Closed

### OFI-141 — The compiler built on macOS only (a cluster of build-time macOS-isms, not a language dependency) — CLOSED
*Filed + closed 2026-06-24 when Linux became a first-class target. Root-caused against real Linux via Docker (`gcc:13`/glibc 2.36 and `ubuntu:24.04`, x86_64) — every fix below was driven by an observed failure, not by reasoning about portability.*

**Surprise.** The reference compiler is clean POSIX C17 — no `__APPLE__`, no `mach/*`, no frameworks, no `mmap`/`MAP_ANON`, no arch assumptions, and the stdlib-locate path already uses `realpath(argv[0])` (portable) rather than Apple's `_NSGetExecutablePath`. The architecture had already done the hard part. What blocked Linux was entirely in the *build*, and every item was invisible under Apple clang/libc:

1. **glibc feature-test macros.** `-std=c17` is strict ISO C, under which glibc hides the POSIX functions the compiler uses — `realpath`, `popen`/`pclose`, `strdup` (×18), `random` (×17), `clock_gettime`, and the `sysconf(_SC_NPROCESSORS_ONLN)` macro. With `-Werror` these are hard errors. Apple's libc exposes them regardless, so the Mac never saw it. Fix: `-D_DEFAULT_SOURCE` (re-exposes them without leaving the C17 core; a no-op on macOS), added to every compile flag group.
2. **libm.** On Linux libm is a separate library; on macOS it is folded into libc. Every math builtin (`sqrt`/`pow`/`sin`/`floor`/…, from cextern.c/vm.c/runtime.c) was an undefined reference at link. Fix: `-lm` appended **after** the objects on every link line (link order matters with `--as-needed`), and in the native `emberc -o` command (src/main.c).
3. **pthread.** The parallel/threaded builds relied on pthread living in libc (true on macOS) and passed no link flag. Fix: `-pthread` on the `EMBER_PARALLEL` flag groups (the native concurrent link already passed `-lpthread`).
4. **Two real bugs gcc `-Werror` caught that clang waved through.** (a) `char cn[24]` in cgen_c.c held a copy of a `cname[40]` — `-Wformat-truncation` proved it could truncate a **generated C identifier** into a different name: a latent miscompile, not a style nit. Sized the buffer to the field. (b) `SemType at[MAX_PARAMS]` in check.c (×2) tripped `-Wmaybe-uninitialized` at `-O2` (the dev build is `-O0`, so only optimized builds saw it) — a false positive, but the conventional fix (`= {0}`) makes it provably safe.
5. **The gate scripts carried their own un-ported `cc` lines.** `tools/opcheck.sh` (the `-DEMBER_OPCHECK` VM) and `tools/crucible.sh` (the drop-trace build) compile `src/*.c` directly, bypassing the Makefile — they needed `-D_DEFAULT_SOURCE` + `-lm` too.
6. **ASan parity.** gcc enables LeakSanitizer by default on Linux (off/unsupported on macOS), so crucible's ASan oracle fired on the compiler's intentional bump-arena retention at exit — a non-bug — duplicating crucible's own RSS leak oracle. Fix: `ASAN_OPTIONS=detect_leaks=0` for parity (leaks stay RSS-verified). And `rss_of` used the BSD `/usr/bin/time -l`; made it cross-platform (`time -v` on Linux, KB-normalised).

**Proof.** On x86_64 Linux: dev + release + parallel + native all build; **regression 384/0**; **all 7 verify gates green** (build, parallel, test, opcheck, ceilings, ledger, crucible). The macOS host was re-verified after every change — all 7 gates green there too, so the one Makefile now serves both platforms with no `#ifdef`. The installer (`docs/install.sh`) was de-gated for Linux (apt/dnf/pacman/zypper/apk, with graceful fallback to the plain compiler), and the project's **first CI** (`.github/workflows/ci.yml`) runs the full gate on Linux + macOS so a future macOS-ism that breaks Linux fails in PR. Graphics builds on Linux too (raylib from source); its packaging gap is OFI-142.



### OFI-124 — String-interpolation expressions carried line-1 positions (LSP semantic tokens painted comments) — CLOSED (renumbered from a duplicate OFI-081)
*Opened + CLOSED 2026-06-20 (Karl: VS Code syntax colouring patchy + colours inside comments; Zed solid).*

**Symptom.** In VS Code, `examples/05_concurrency.em` showed stray colours, including *inside comments*.
**Diagnosis (not the grammar — verified by running the real `vscode-textmate` engine: the TextMate
grammar tokenises correctly, and the installed grammar == repo).** The difference between the editors
is **LSP semantic tokens**; decoding them for the file showed 27/69 tokens MISPLACED, several painted
onto the header comment. **Root cause:** the parser re-lexes each `{…}` interpolation hole as a
standalone string (`lexer_scan(hole, …)`), so identifiers inside `{ }` got **hole-relative positions**
(line 1, col N) in the semantic index — which the semantic-tokens pass then painted onto the file's
line 1 (a comment). Two compounding leaks: the semantic-tokens handler iterated **all** index entries
with no `ref_file` filter (so imported-module entries leaked too), and three recorders
(`sem_record_local`/`field`/`method`) never set `ref_file`. **Fix (three layers):** (1) parser offsets
each re-lexed hole token to its true file position (also fixes hover/go-to-def on interpolated
identifiers, and corrected the `interpolation.bytecode` line info — golden reblessed); (2) set
`ref_file` on every recorder + filter semantic tokens to the current doc; (3) defence-in-depth — a
semantic token must cover a real, word-bounded identifier or it is dropped (never paint a comment /
operator). All examples now 0 misplaced; ASan-clean; regression in `tests/run-lsp.sh` asserts no token
lands in a comment and interpolated identifiers tokenise at their real line. (Why only VS Code showed
it: it applies the LSP semantic tokens over TextMate; Zed leaned on its tree-sitter layer and masked
the bad tokens — but the bug was server-side, so the fix helps both.)

### OFI-080 — `docs/grammar.ebnf` had drifted from the parser (external review caught it) — CLOSED
*Opened + CLOSED 2026-06-20 (a reviewer's 8-point grammar review; the grammar header says "keep the two in sync").*

**Two rules were genuinely STALE vs `src/parser.c`:** (1) `Primary` never listed the **lambda** production
though the parser implements `|params| (block | expr)` (EXPR_LAMBDA) — a comment hinted at it but no
rule formalised it; (2) `GenericParam` showed a single bound `[":" , ident]` but the parser parses
`+`-separated multi-bounds (`T: Hash + Eq + Copy`, the `Map<K,V>` machinery). Both fixed: added
`Lambda`/`LambdaParam` rules + `| Lambda` in Primary, and `{ "+" , ident }` on GenericParam.

**Three under-documented points clarified** (places a reader — for an LLM-first language, a *model* —
gets confused): (3) **newline termination + method chains** — the (N) note + language.md now spell out
that continuation is TRAILING-operator and that `foo<newline>.bar()` (leading dot) does NOT chain while
`foo.<newline>bar()` does (verified empirically — leading-dot is a parse error; opposite of Swift/JS,
so a real least-surprise gap); (4) `?` documented as Result/Option unwrap-or-early-return; (5) `match`
exhaustiveness + the `_` wildcard noted. **Three points had no merit** (reviewer right or misread): the
generic-vs-comparison rule (G) is sound (`foo<bar>(baz)` → comparison, since `>` isn't followed by `{`);
field-vs-method (`fn` disambiguates); and the import model (one `import … as alias` → qualified
`alias.member`, not per-item imports). No code change — docs only; grammar now matches the parser.

### OFI-079 — Diagnostics were attributed to the entry file, not the module being checked — CLOSED
*Opened + CLOSED 2026-06-20 (surfaced by OFI-078: errors from inside `std/ui.em` appeared on the open file).*

**Symptom.** Opening a file that imports a module with errors painted squiggles on the importer at the
imported file's line numbers — e.g. `examples/11_menus.em` (72 lines) showed diagnostics up to line
1168, the lines of `std/ui.em` (1215 lines). **Root cause.** Every checker diagnostic used `c->src` — a
single field set once to the entry file — so an error raised while checking an imported module was
reported as `(entry_file, that_module's_line)`. The LSP filter `di.file == d->path` then passed them
(file matched the open doc; only the line was foreign). **Fix.** New `diag_src(c)` returns the path of
the module currently being checked (`c->modules->modules[c->current_module].path`), used by
`type_error` and every direct `diag_error`/`diag_note`; the existing LSP filter now correctly drops
imported-module diagnostics. Regression in `tests/run-lsp.sh`: a module with a type error imported by a
clean app yields zero diagnostics on the app.

### OFI-078 — Graphics primitive signatures were gated out of the checker (`#if EMBER_GRAPHICS`) — CLOSED
*Opened + CLOSED 2026-06-20 (Karl: red squiggles all over a graphics dogfood in Zed after `make install`).*

**Symptom.** Every `u.method()`/`draw.fn()` in a graphics program flagged "call to an undefined
function" in the editor, even though hover resolved them. **Root cause.** The graphics primitives'
*signatures* (the `NATIVE_GFX_*` enum, the name→nid map, and the arity/type check) were all behind
`#if EMBER_GRAPHICS`, so the default (dependency-free) build's checker — which the installed LSP runs —
didn't know them; `std/ui`/`std/draw` failed to type-check, cascading to every call site. Confirmed by
running the LSP on the file: default build = 182 diagnostics, graphics build = 0. **Fix (Karl's call:
decouple signatures).** The signatures are pure type data with no raylib dependency, so they are now
compiled into EVERY build (ungated in `include/builtin.h`, `src/builtin.c`, `src/check.c`); only the
*implementation* (raylib backend + VM / native-backend dispatch) stays `#if EMBER_GRAPHICS`. The VM
no-ops an unknown nid, so a default build type-checks a graphics program but cannot run it (use `make
graphics`). The LSP's `publish_diagnostics` also switched to a CHECK-ONLY path (`check_diagnostics`,
no codegen) — correct LSP semantics, and it never touches the gated lowering. Now the default-build LSP
reports 0 diagnostics on `examples/{09_ui,11_menus,17_flare}.em`; a wrong-arity graphics call and a
genuinely undefined function both still error. `make test` 353, `make test-lsp` 8 sections green.

### OFI-125 — Flare rich-text regressions: code blocks rendered EMPTY + bold runs lost their spacing — CLOSED (renumbered from a duplicate OFI-078)
*Opened + CLOSED 2026-06-20 (Karl spotted empty code blocks in the live flare_chat app — the dogfood caught what the goldens didn't).*

**Symptom.** Two rendering bugs surfaced once real Claude replies (formatted prose + fenced code) flowed
through the new chat-turn layout: (1) fenced **code blocks drew nothing** — just empty space where the panel
should be; (2) inline **bold runs lost the spaces** around them ("a simple**To-Do List Manager**with").

**Root causes.** (1) `_code_block`/`_quote_block` reserved their slot with `leaf(0, h)` and relied on the
parent column being **STRETCH**-aligned to get full width. But step 2's avatar layout puts the message in a
`column(START, START)` — START align does NOT stretch children — so the code leaf got width **0**; the surface
fill and the clip were both `w:0`, clipping the (correctly drawn, even syntax-highlit) source to nothing. The
tape made it obvious: `{"op":"round",…,"w":0,…}` + `clip_push …"w":0`. (2) `rich_text` sized each coalesced run
by SUMMING per-word widths plus `measure_text(" ")` for the inter-word spaces — but a lone space under-counts
(`measure(" ")=4`) versus the real in-context space (`measure("a b")−measure("a")−measure("b")=6`; the renderer
adds inter-glyph spacing around a space). So every run was a few px too narrow, the rendered text overran its
leaf, and the next run abutted it — no gap.

**Fixes (`std/flare.em`).** (1) `_code_block`/`_quote_block` now take an **explicit width** (`leaf(width,h)`),
so they render in START- *or* STRETCH-aligned parents alike. (2) `rich_text` derives the true space as
`measure("a b")−measure("a")−measure("b")`, and `_emit_line` now measures each coalesced run **exactly** in its
own face (`measure_text(seg)`) instead of summing word widths — so leaf width == rendered width and the row gap
is a real space. Verified in-app via tape (code panel `w:544` with highlit `print`/`x`; bold runs now gap
correctly). Regression `tests/graphics/flare_codeblock.em` (a fenced block + bold inside a START column —
the exact scenario); `flare_rich`/`flare_avatar` re-blessed. graphics 16 green, `make test` 353/0.

**Lesson.** The goldens had rich text but NOT a code block inside a START column, so they missed it — the live
dogfood app found it. A STRETCH-dependent `leaf(0, …)` is a latent trap; prefer explicit sizes.

### OFI-077 — Flare inline emphasis uses non-coherent FAUX faces (only Inter Regular is embedded) — OPEN
*Opened 2026-06-20 (building Flare's inline rich text so Claude replies render **bold**/*italic*/`code`).*

**Symptom / compromise.** `rich_text` now renders inline Markdown emphasis, but the body face (embedded
Inter Regular, slot 0 in `graphics.c`) has no bundled bold or italic companion, so: **bold** is *faux-bold*
(the glyph drawn twice 1px apart) and *italic* borrows the SYSTEM face `/System/Library/Fonts/SFNSItalic.ttf`
(SF, not Inter — a slight typeface mismatch mid-line). Both look fine and degrade gracefully (a missing SF
italic falls back to the body face), but they aren't a true, coherent type family the way real Claude's are.
Monospace inline `code` already uses SFNSMono, which is fine (code is meant to contrast).

**Why it's stdlib-only for now.** A crisp, coherent fix is to embed **Inter Bold + Inter Italic** as static
faces beside `font_inter.h` and select them by slot — but that's a CORE change (`src/graphics.c` + new font
headers), owned by the compiler/runtime work, not the Flare/stdlib layer. Faux-bold + borrowed-italic is the
best achievable purely in `std/flare.em`.

**Fix (future, core asset).** Embed Inter Bold/Italic (or a variable Inter with weight/slant axes wired
through `set_font`), then point `_font_for(_BOLD)`/`_font_for(_EM)` at real slots and drop the double-draw.
Also outstanding rich-text follow-ons (feature gaps, not bugs): clickable links (needs a URL-open FFI),
inline emphasis inside blockquotes/headings (currently stripped there), and Markdown tables.

### OFI-076 — `docs/flare.md`'s counter example called a non-existent API (wouldn't compile) — CLOSED
*Opened + CLOSED 2026-06-20 (found while extending Flare with the modal + segmented controls).*

**Symptom.** The headline "counter component" example in `docs/flare.md` could not compile: it called
`f.row_begin()` / `f.row_end()` (the API is `f.row(justify, align)` … `f.end()`), `f.heading("Counters", 388)`
(heading takes only `(s)` — width is implicit from the slot), and drove the frame with a bare `draw.finish()`
with no matching `f.finish()` and a dangling `f.end()`. A reader copy-pasting the documented component hit four
compile errors — a direct violation of the working agreement that **every example must compile and run**.

**Root cause.** The doc predated the layout-engine rewrite that replaced the old `*_begin/*_end` cursor API
with the flexbox `row/column(justify, align)` + `end()` model and the auto-sized `heading(s)`; the prose API
list was updated but this code block was not. Documentation drift, not a compiler bug.

**Fix (`docs/flare.md`).** Rewrote the example against the real API (mirroring the proven
`tests/graphics/flare.em`): `f.row(flare.START, flare.CENTER)` … `f.end()`, `f.heading("Counters")`, and a
correct `f.begin()` … `f.finish()` frame. Also documented the new `modal_begin`/`modal_end`, `segmented`, and
`divider` in the same pass so the API reference matches `std/flare.em`. (Lesson: the doc example should ideally
be a tested snippet — a future test-infra item, like the README-extraction harness.)

### OFI-075 — LSP emitted UTF-8 byte offsets but never negotiated `positionEncoding` — CLOSED
*Opened + CLOSED 2026-06-20 (found while making `emberc --lsp` compatible with Zed; it bit VS Code latently too).*

**Symptom.** Every LSP position (diagnostics, go-to-definition / document-symbol ranges, and the incoming
hover/definition/completion cursor) was treated as a **byte** offset, but the LSP base protocol defaults the
`character` unit to **UTF-16** code units. With ASCII source byte==UTF-16, so it "happened to work" — but any
non-ASCII byte in a comment or string literal *before* a token (e.g. `return "héllo " + nme`) shifted every
squiggle/hover/jump on that line by the number of multi-byte code points, in any client that didn't speak utf-8.
Not Zed-specific — VS Code was equally affected; it just rarely showed because Ember code is mostly ASCII.

**Root cause.** The compiler tracks columns in bytes end-to-end (`Token.col`/`length`), and `src/lsp.c`
serialized those byte columns straight into LSP positions (and matched incoming positions straight against
them) with no encoding negotiation in the `initialize` response.

**Fix (`src/lsp.c`).** Negotiate per LSP 3.17: read `capabilities.general.positionEncodings`; advertise
`"utf-8"` (our native byte offsets — zero conversion) when the client offers it, else fall back to `"utf-16"`
and translate columns at the wire. A small encoding module (`byte_to_char`/`char_to_byte`, walking the line's
UTF-8 only when utf-16 was negotiated and the line carries a byte ≥ 0x80; ASCII and the utf-8 path are
identity) wraps every outgoing position (`publish_diagnostics`, `put_range_obj`, `put_symbol_head`) and every
incoming one (hover/definition/completion + `decl_under_cursor`). Cross-file definition ranges convert against
the target doc's text when it is open, else identity (declaration lines are ASCII before the name). Correct for
**any** standards-compliant client (Karl's "full utf-8/utf-16 fallback" call). Regression in `tests/run-lsp.sh`:
asserts utf-8-preferred / utf-16-fallback negotiation **and** that the `nme` diagnostic lands at byte col 23
under utf-8 vs UTF-16 col 22 under utf-16. `make test` (352) and `make test-lsp` both green.

### OFI-067 — `declare_local` left `Local.frozen` (slice-borrow flag) uninitialized — CLOSED
*Opened + CLOSED 2026-06-18 (surfaced converting `Checker.locals` to a dynamic vector for the `local` ceiling).*

**Symptom.** `examples/14_cli.em` suddenly failed to compile with a flurry of spurious "cannot mutate an array
while it is borrowed by a slice (the view would dangle)" errors. **Root cause:** `declare_local` (and
`reserve_hidden_slot`) set every `Local` field *except* `frozen`/`frozen_line`/`frozen_col`, relying on the old
fixed `Local locals[256]` buffer happening to be zero. When a slice freezes a slot and that slot is later reused
by a new binding, the stale `frozen=1` leaks → the new array reads as slice-borrowed. The dynamic
(arena-grown, reused-across-functions) buffer changed the reuse pattern and exposed the latent bug. **Fix:**
zero-initialise the whole entry (`c->locals[i] = (Local){0};`) before setting its fields, in both
`declare_local` and `reserve_hidden_slot` — a fresh binding owns no freeze/move state. Suite back to 321 green;
the same `(Local){0}` guards against any future field being forgotten.

### OFI-059 — String interpolation leaked its intermediate heap temporaries — CLOSED
*Opened 2026-06-17, CLOSED 2026-06-18 (fixed at Karl's "do it slow and steady" call, after it was flagged as the open item most likely to hurt long-running UIs — immediate-mode GUIs interpolate labels every frame).*

A loop binding an interpolated string (`let s = "item {i}"`) grew RSS **linearly** (~124 MB at 2M
iterations); the *final* string was dropped, but the **intermediate concat results** were never released.
**Root cause:** the interpolation fold (`EXPR_STRING`, `src/codegen.c`) concatenated with **`OP_ADD`**, which
does NOT consume its operands (correctly — general `+` operands may be borrowed locals), so each fold step's
intermediate string was popped off the stack and leaked. The native backend already did it right (`em_add`
consumes + interned literals/`em_to_string` own). **Resolution (VM-only, mirroring the native model):**
1. New opcode **`OP_CONCAT`** — string concat that **consumes (releases) both operands** — emitted by the fold
   instead of `OP_ADD`. Sound because every fold operand is OWNED: an interned-literal push (`OP_STRING`
   retains), an owned `OP_TO_STRING` result, or a prior `OP_CONCAT` result.
2. **`OP_TO_STRING`** now **retains** an already-a-string passthrough, so a `{string_var}` hole yields an owned
   reference the consuming concat can release without freeing the borrowed source. (General `+` still uses the
   non-consuming `OP_ADD`, untouched.) **Bonus fix:** this also closed a *latent* over-release — single-hole
   `let x = "{s}"` was a drop=1 binding over a passthrough borrow, which over-released the interned literal in a
   loop; `x` now owns its reference. Native backend unchanged (already correct).

**Verified:** RSS **FLAT at 2 MB through 2M iterations** (was 124 MB); correct output for single/multi-hole,
borrowed-string holes, and loops; ASan-clean incl. the single-hole-in-a-loop case; VM↔native differential
identical; codegen goldens re-blessed (`ADD 0`→`CONCAT`); full suite 316 green + graphics 11/0. Regression:
`tests/run/interpolation_ownership.em`. **Residual (separate, rarer):** general `f() + g()` / `acc + ownedTemp`
string concat still leaks an owned operand in the VM (the non-consuming `OP_ADD`) — the native backend handles
it via `em_add`+retain-borrowed; closing it in the VM means making `OP_ADD` consume + retaining borrowed
operands in codegen, a broader change to a hot opcode. Not the interpolation bug, and uncommon in UI label code.

### OFI-061 — Couldn't assign a field through an array index (`arr[i].field = v`) — CLOSED
*Opened + CLOSED 2026-06-17 (hit building the Flare Todo app; fixed same session at Karl's "ASAP" call).*

`arr[i].field = v` was rejected with "a field assignment must be rooted at a variable", so flipping one field
of a struct stored in an array (e.g. a `Todo.done` in a `[Todo]`) forced **parallel arrays** of Copy columns
or a full functional rebuild. **Root cause:** the checker's field-assignment root-walk ([src/check.c]) only
traversed `EXPR_GET` steps, so `ps[0].x` stopped at the `EXPR_INDEX` and failed the root check — while the
element-assignment path right beside it already walked through `EXPR_INDEX`. **Resolution, three layers:**
1. **Checker** — the root-walk now traverses BOTH `EXPR_GET` and `EXPR_INDEX` (so `arr[i].field` and
   `a[i].b.c` root at the array var), keeping the same mutability + slice-borrow guards.
2. **VM codegen** (`gen_nested_store`) — array struct-elements are stored INLINE, so reading `arr[i]`
   materialises a COPY; a plain `SET_FIELD` would mutate a discarded temporary. Added a read-modify-WRITEBACK:
   set the leaf on the copy, then `OP_SET_INDEX` it back. Refcount-balanced and leak-free by construction —
   `OP_INDEX` retains the copy's boxed leaves, `OP_SET_FIELD` releases the old leaf, `OP_SET_INDEX` releases
   the old element — net exactly one owner (mirrors the existing inline-nested-field writeback).
3. **Native backend** (`cgen_c.c`) — same writeback in C via `em_index`/`em_set_field`/`em_set_index`,
   hoisting array+index to temps (eval once). Placed BEFORE the boxed/value-struct split, because a
   **non-flat** element struct (one with a heap field, e.g. `string`) is not an `is_value_struct` yet is still
   stored inline — so it must take the writeback too (this was a second bug the string-field case exposed).

**Verified:** `arr[i].field = v` correct on VM and native for scalar AND `string` fields (incl. reassigning a
string, releasing the old); VM↔native differential `tests/native/struct_array_field.em`; 200k string-field
reassigns ASan-clean (no UAF/double-free) and RSS-FLAT at 2 MB through 2M iters (no leak — the earlier apparent
growth was OFI-059's interpolation leak, reproduced standalone); full suite 315 green + graphics 11/0.
**Follow-up fix 2026-06-18:** the native writeback had a latent bug — its hoist temps used the `a%d` prefix,
which **shadows the C function parameters** `a0,a1,…` (`self`/args), so `self.cells[i].field = v` inside a
METHOD compiled to `Value a0 = …a0…` and segfaulted (the VM was fine; `main()`-only tests missed it). Fixed by
naming all writeback temps `v%d`. Covered by a method case in `tests/native/struct_array_field.em`. Found by
probing the exact primitive `std/layout` needs before building on it.
**Residual (separate, narrower):** moving a WHOLE element out of a still-live array by value (`f(items[i])`)
is still a partial-array move — but the array-of-structs pattern no longer needs it (borrow the fields, write
back the field). If it ever does, the runtime's structural deep-clone (the same `own_into_slot` that lets a
struct be a `Map` key, OFI-042) could clone the element on read rather than move it — no `Clone` interface
required.

### OFI-060 — Graphics backend rendered at logical resolution on HiDPI/Retina displays (blurry text) — CLOSED
*Opened + CLOSED 2026-06-17 (found while scoping the UI-quality campaign — "make fonts render nicely for modern displays").*

`ember_gfx_window_open` (`src/graphics.c`) set `FLAG_WINDOW_RESIZABLE | FLAG_MSAA_4X_HINT` but **not
`FLAG_WINDOW_HIGHDPI`**. On a Retina panel (2× backing scale) raylib therefore created a *logical*-resolution
GL framebuffer and let macOS upscale the whole presented image — so a 16 px UI string was rasterised into 16 px
of real coverage and then stretched 2×, the soft/muddy look the campaign targets. (`MSAA_4X_HINT` does nothing
for text — glyphs are textured quads, not geometry edges.) **Resolution:** enabled `FLAG_WINDOW_HIGHDPI`,
captured `GetWindowScaleDPI()` into a module-level `g_scale` (re-read each frame so dragging between displays
tracks), and render the frame under a `Camera2D` whose `zoom == g_scale`, so the whole toolkit keeps describing
the UI in **logical points** while the GPU maps them to physical pixels. raylib already DPI-scales
`BeginScissorMode`, the mouse, and `GetScreenWidth/Height` on Apple, so clips/input/layout stay logical and
consistent with the camera — no per-call scaling anywhere. At scale 1.0 the camera is the identity transform, so
1× output is unchanged. **Verified:** clean `-Wall -Wextra -Werror` build; all 9 `tests/run-graphics.sh` golden
UI tapes match (1× regression-free). *Caveat:* the Retina win is correct by construction but not yet eyeballed on
real Retina hardware (none on this machine — both displays are 1×). Recorded as a `## Decision:` in
docs/architecture.md. Follow-on text-quality work (FreeType hinting for crisp small text on 1× LCDs, gamma/
stem-darkened blending, LCD subpixel AA) is the next phase of the campaign — tracked there, not under this item.
**Hardware regression found + fixed 2026-06-18** (the "never eyeballed on Retina" caveat bit us):
on a real 2× Retina MacBook the whole UI rendered **2× oversized** — a user reported the text/buttons
were huge. ROOT CAUSE: this fix's `Camera2D` zoom was redundant. raylib's `FLAG_WINDOW_HIGHDPI`
projection *already* maps logical points onto the physical framebuffer (a 1100-pt window fills a 2200-px
buffer), and `BeginScissorMode` DPI-scales clips the same way on Apple — so the extra `cam.zoom == g_scale`
double-scaled everything (measured: the 264-pt sidebar landed at 48% of the window instead of 24%).
**Fix:** removed the camera entirely; draw in logical points and let raylib's projection do the mapping.
`g_scale` is now derived from the real framebuffer ratio (`GetRenderWidth/GetScreenWidth`, not the
monitor's `GetWindowScaleDPI`) and used *only* to bake glyphs at device-pixel size, so text stays crisp.
Verified by measuring the rendered framebuffer (sidebar divider back at 24%); goldens 12/12 (draw-lists
are logical, so unaffected). Applies to ALL graphics apps, not just gui.em.

### OFI-058 — A borrowed value-struct local was double-freed when exploded into a multi-slot param — CLOSED
*Opened + CLOSED 2026-06-17 (the Claude-desktop app crashed on close: "pointer being freed was not allocated").*

The desktop GUI crashed on exit (`malloc: pointer being freed was not allocated`, SIGABRT) in `vm_destroy`
→ `free_objects` → `free_list`. **ROOT CAUSE** (found by adding a double-drop detector to `reclaim` — stamp
a sentinel after a reclaim, abort + backtrace on a second reclaim before reuse — plus reading the bytecode):
`gen_arg` (codegen.c) explodes a struct ARGUMENT into a multi-slot param's field slots. For a heap-boxed
struct **named local** passed BY BORROW (used again, e.g. every loop iteration, so `moves_local != 1` and
the slot is NOT nilled), it emitted the reclaiming **`OP_UNBOX_STRUCT`** — which frees the shell after
exploding. That frees the LIVE local's box; the local's scope-exit `OP_DROP` then frees it a SECOND time →
the object list / pool is corrupted → the abort at exit. A move (last use, slot nilled) was fine — only the
borrow path double-freed, and only for a heap-boxed local (a struct from a call result like `var th =
dark_theme()`); a multi-slot-inline local takes the no-reclaim GET_LOCAL path, so literals didn't trip it.
The app hit it because `th`/`Theme` (17 ints) is passed by value to the render functions every frame.

**FIX:** a new opcode **`OP_UNBOX_STRUCT_BORROW`** (vm.c) — like `OP_UNBOX_STRUCT` but it RETAINS each heap
leaf (the source keeps ownership; the callee's param releases its copy) and does NOT reclaim the shell.
`gen_arg` emits it when the arg is a borrowed named local (`EXPR_IDENT && moves_local != 1`), and the
reclaiming form otherwise (fresh temp / moved-out local). **Why ASan was blind without help:** the object
pool recycles instead of `free()`-ing, so the double-free reads valid (re-allocated) memory; caught with a
pool-poison / no-pool ASan build, then pinned with the reclaim double-drop detector. Verified: the app +
the frame-capped app run ASan-CLEAN; 311 goldens + 9 graphics + 265-program ASan corpus clean; a 500k-loop
struct-with-string borrow stays flat-RSS (the retain is balanced). Regression: `tests/run/struct_borrow_arg.em`.

**NATIVE BACKEND CONFIRMED CLEAN (2026-06-17).** The AST→C backend was checked separately (its differential
tests only compare stdout, so a benign double-free could hide): the runtime was rebuilt with ASan + the
`reclaim` double-drop detector (now a permanent opt-in via **`-DEMBER_DROP_TRACE`**, the "memory tape"), the
`--emit=c` output for the borrow-unbox repros + ALL 39 `tests/native/*.em` was compiled against it and run →
**39/39 + repros CLEAN**, with a POSITIVE CONTROL (injecting a duplicate `drop_value` into the emitted C made
the detector fire) proving it was actually exercised. The native backend does NOT share OFI-058 by
construction: it lowers value-structs to **real C structs** (value copies — an all-scalar struct emits ZERO
drop calls), so there is no heap-boxed shell to double-free; the bug was specific to the VM's boxed/multi-slot
representation + `OP_UNBOX_STRUCT`'s reclaim. See [[ember-asan-available]], [[trust-the-tape]].

### OFI-057 — `alloc_struct_array` left `ObjArray.borrowed` uninitialized (garbage → spurious slice) — CLOSED
*Opened + CLOSED 2026-06-17 (found while chasing the desktop app's "cannot append to a slice view").*

`alloc_struct_array` (the allocator for an array of all-scalar structs stored INLINE, `AEK_INLINE_STRUCT`)
set every field EXCEPT `a->borrowed` — unlike `alloc_array`, which explicitly does `a->borrowed = 0`. Since
`pooled_alloc` returns DIRTY memory (recycled pool slot or fresh `malloc`, never zeroed), an inline-struct
array read a garbage `borrowed` byte. When that byte was non-zero the array was mistaken for a read-only
**slice view** → `cannot append to a slice view` mid-run, and at drop/`free_list` the `if (!borrowed)
free(data)` branch was skipped (leak) or mishandled. Exactly the [[ember-arena-node-init]] class ("every
per-kind field must be init'd at its creation site"), but for the object pool rather than the AST arena.
**Layout-dependent heisenbug** (whether the garbage byte is non-zero depends on the previous slot occupant),
so it only reproduced under ASan/specific layouts — minimal repro: `var a: [S] = []` for an all-scalar `S`,
heavy `a.append(S{..})` under `build/emberc-asan`. **ASan is blind to it normally** (the pool keeps memory
"allocated"); caught via a no-pool / pool-poison ASan build. **Fix:** add `a->borrowed = 0;` to
`alloc_struct_array` (runtime.c:423). A parallel audit of ALL allocators (alloc_array/slice/struct_array/
instance, make_string) confirmed this was the ONLY missing-init bug. Verified: the failing repros pass; 310
goldens + 9 graphics + the 265-program ASan corpus all clean. Regression: `tests/run/inline_struct_array.em`.

### OFI-054 — Native-backend (AST→C) residual edge cases — CLOSED
*Opened 2026-06-17; closed 2026-06-17 (two fan-out-investigate-then-implement passes).*

The native backend once rejected several constructs the VM accepts, each with a clean `cgc_error`. **All
are now SHIPPED — the native backend compiles everything the VM accepts** (verified by a full differential
sweep: 0 native deferrals; the only VM-vs-binary difference is concurrent-print interleaving in
`nursery_spawn`, which is inherent — real threads vs the VM's cooperative scheduler — not a miscompile).
310 green; every path RSS-verified leak-free.

1. **Arrays of structs** — `[Point]` (inline + heap-bearing elements): literal (`em_struct_array`), index
   (value COPY), `.append`/index-set, `.remove_last` (move-out), `.slice`; an inline value-struct element
   round-trips as an `em_s` (the producer returns a boxed copy, the binding/match site unboxes).
2. **Array slice VIEWS** `arr[lo..hi]` — borrowed zero-copy `em_slice` (the checker freezes the source).
3. **`extern "c"` struct-by-value ARGUMENTS** — recursive scalar-leaf flattening into the FFI `in[]`.
4. **Method call on a TEMPORARY receiver** `mk().m()` / `a.f().g()` — evaluate-once-then-drop.
5. **Indexed `for (i, x)`** — binds the element index alongside the element.
6. **Value-struct enum-payload match bind** `case Some(v) { v.method() }`.
7. **Non-flat structs** (a value struct with a nested inline-struct field) in EVERY boxed aggregate —
   array element, enum payload, boxed-struct field, interface receiver (dyn dispatch), and across an erased
   generic by value. `em_box_struct`/`em_unbox_struct` are now recursive (leaf-by-leaf — a raw whole-struct
   memcpy is unsound: the C `em_s` stores each scalar as a 16-byte `Value`, the packed buffer at natural
   width). New runtime: `em_struct_field_inline` (materialise an inline field — the VM's OP_GET_FIELD),
   `em_struct_empty`/`em_struct_put_field`/`em_struct_put_inline` (build-then-place construction — OP_NEW_
   STRUCT), and `em_field_owned` (own an erased bound-method operand so it can be dropped). The hardest
   case (a generic struct with a value-struct key dispatched through a bounded method — `Map<Pt,V>`-shaped)
   needed `em_field_owned` + method-call `drop_mask` to be leak-free (a value-struct key would otherwise
   leak its materialised copy through the witness dispatch; 258 MB → 1.4 MB flat over 2 M iters).
8. **`spawn` of a bounded-generic function** — `emit_spawn` threads the interface witnesses as leading
   args; `em_invoke` gained a witnessed-function case (it previously skipped every `fn_witness_count>0`
   function). Erased generics ⇒ no monomorphization. The witness records are cross-thread freed, which the
   parallel runtime defers to exit (the documented OFI-018 behaviour, same as any spawn).

### OFI-053 — User struct named like a generic type-parameter collides in native by-name resolution — CLOSED
*Opened 2026-06-17 (native M5 survey); closed 2026-06-17.*

The native emitter's `sid_of_struct_type` (src/cgen_c.c) resolved a type purely by NAME, so inside a
generic struct's methods a type-parameter name (`Box<T>`'s `T`, `Map<K, V>`'s `V`) wrongly resolved to a
same-named user `struct T`/`struct V`, mis-typing the erased method's param/return as that value struct
(`em_fn_set(…, em_s2 val)` where `val` should be a boxed `Value`) → a `cc` type error; the VM was always
correct. **Fixed** by teaching the cgen the scope the checker already knows: a new `type_name_is_generic_param(g, fn, name)`
predicate returns true when the name is a generic parameter of the function being emitted OR of its owning
struct, and `sid_of_struct_type` now takes the enclosing `FnDecl` and returns -1 (erased) for such a name
BEFORE the by-name struct lookup. A per-fn-slot owner-generics table (`owner_generics`/`owner_generic_count`
on `CgcGen`, built beside `fn_by_fi`) supplies the owning struct's params; the fn's own generics are read
off its `FnDecl`. Threaded through all three call sites (`param_struct_sid`, `ret_struct_sid`, the
`struct_sid_of` EXPR_CALL path). A genuine value-struct param is untouched (its name isn't a generic param
in scope), so the change is purely the collision suppression. Regression: `tests/native/generic_name_collision.em`
(a user `struct T`/`struct V` alongside `Box<T>`/`Pair<K, V>`; native now matches the VM bit-for-bit).

### OFI-048 — `mut self` on a `let` receiver is silently accepted — CLOSED
*Opened 2026-06-15 (surfaced verifying the H5 mutable-borrow fix); closed 2026-06-17.*

Calling a `mut self` method on an immutable `let` receiver compiled without a diagnostic, so a value-copied
scalar struct mutated a throwaway copy (the change silently lost) and a boxed/array-field struct could
mutate through a reference a `let` was meant to freeze — the same soundness shape as the explicit-`mut`-
parameter hole H5 closed, but on the method-receiver path. **Fixed** in the struct-method-call check
(src/check.c): when `mi->self_qual == OWN_MUT`, the receiver is walked down `EXPR_GET`/`EXPR_INDEX` to its
root and, if that is a non-`var` local binding, rejected ("cannot call a 'mut self' method on an immutable
binding; declare it 'var' (or take 'mut')") — mirroring the existing `mut`-argument place check. A fresh
temporary receiver (`mk().m()`) and a `move self` method are correctly exempt; `self` inside a `mut self`
method is already `is_var`, so self-to-self mut calls still pass. Zero existing programs broke (every
`mut self` call site in examples/tests/std was already on a `var`). Regressions:
`tests/run/error_mut_self_on_let.em` (rejected) and the positive `var` case verified.

### OFI-047 — Struct/enum/closure type-ids are emitted as a single unguarded byte — CLOSED
*Opened 2026-06-15 (the OFI-007 lesson applied to the remaining opcodes); closed 2026-06-17.*

`OP_NEW_STRUCT` (struct id), `OP_NEW_ENUM` (enum id), and `OP_MAKE_CLOSURE` (fn index) wrote their id as a
single byte with no overflow guard, while `OP_CALL` had been widened to 16 bits (OFI-007). This was worse
than "purely defensive": the struct-id space is `base structs + monomorphized generic instances` and the
closure-fn-id space is `the whole function table + lifted lambdas` — each a SUM of separately-capped (256)
pools, so a large program could produce an id > 255 that wrapped mod 256 and built the WRONG type/closure
(a latent silent miscompile, not just a future cap-bump risk). **Fixed** with a guard helper `emit_u8_id(cg,
id, what)` (src/codegen.c, modelled on `emit_fn_index`) that turns an out-of-range id into a clean compile
error (`cg->had_error`) instead of a silent wrap; applied at all seven single-byte id-emit sites (struct,
closure×2, and the enum-id sites for symmetry). Widening the operands was rejected — it would churn the
opcode operand table + VM decoder + disassembler for ceiling headroom only call sites need. Behaviour is
identical for every program whose ids fit a byte (full suite green, `tests/codegen/*.bytecode` byte-
identical); a real >256-pool repro is impractical (the per-category caps block it), so this is a verified
safety guard rather than a runnable test.

### OFI-045 — A bounded generic function's type parameter isn't accepted as a bounded type argument — CLOSED
*Opened 2026-06-15 (surfaced writing `std/set`); closed 2026-06-17.*

A generic function bounding its own type parameter (`fn new_set<K: Hash + Eq + Copy>() -> Set<K>`) could not
use `K` as a type argument to a generic struct with the SAME bound — `Set<K>{...}` was rejected ("a type
argument does not satisfy the struct's generic bound") even though K's declared bounds cover it. This blocked
generic *constructor* functions, forcing the stdlib to build collections from literals at concrete types.
**Fixed** in `type_satisfies_bound` (src/check.c): a new `type_param_has_bound(c, t, iid)` accepts an
in-scope type parameter whose DECLARED interface-bound set contains the required bound (a sound ⊇ rule). The
`Copy` bound is deliberately NOT touched — it is not an interface bound and is enforced separately via
`is_move_type` at each construction/call site, so a param missing `Copy` is still rejected. Regressions:
`tests/run/generic_bounded_ctor.em` (positive — a bounded constructor now compiles + runs); both negatives
verified (missing Hash → bound error; missing Copy → Copy error).

### OFI-052 — Native backend drop discipline incomplete (memory leaks) — CLOSED
*Opened 2026-06-17 (M3 code review); closed 2026-06-17 (full native drop-discipline campaign).*

The native backend leaked memory in several output-correct-but-unbounded ways (the differential suite
checks stdout, not RSS, so they were invisible there). All are now FIXED — every case verified flat
(~1.4 MB peak RSS, unchanged across millions of iterations) and bit-identical to the VM:

1. **Heap-bearing structs are now BOXED, not value-type C structs.** A struct is lowered to a value-type
   `em_s<sid>` only if it is all-scalar RECURSIVELY (`is_value_struct`, src/cgen_c.c); any struct with a
   string/array/enum field (a Config, or `Map`/`Set` with their bucket array + witness fields) is a heap
   `ObjStruct` like the VM, so `drop_value` releases its fields. New runtime: `em_struct` (construct,
   moves fields), `em_set_field` (field write, drops the old value — was leaking on reassignment). Boxed
   structs flow through the existing boxed machinery: field read via `em_enum_field`, methods take a boxed
   `Value self` (mut-self mutates the shared heap object), construction boxes, moves/drops use the checker
   flags. Generic struct INSTANCES still alias to their base typedef where they ARE value-type.
2. **String literals are interned** at their emit site (one object per literal, retained per use), matching
   the VM — concat operand temporaries no longer leak.
3. **`+` and `==`/`!=` consume their operands** (em_add / em_eq_op / em_neq_op drop both), with the emitter
   retaining a borrowed operand (`emit_concat_operand`) so the consume balances without double-freeing a
   borrowed string param. `em_to_string` retains a string input so an interpolation fold can consume it.
4. **Owned temporary call arguments** are dropped after the call via the checker's `drop_mask` (the
   value-struct<->boxed bridge made a masked arg always a single boxed Value).
5. **Bounded-generic witness records and boxed struct returns** are dropped after the call
   (`emit_generic_call` hoists witnesses into locals + drops them; unboxes then drops a boxed value-struct
   return).
6. **Escaping boxed-field reads** (`return c.host`, `let x = c.host`) are retained so they survive the
   owning struct's drop (the VM only "worked" here by reading freed memory — a latent bug this exposed);
   **`.len()` on a temporary receiver** drops the receiver.

Also fixed in the same pass (the M3 review's *dangerous* findings — compile failures / silent miscompiles /
a runtime panic): interface upcast in a `let` typed as `em_s` (now honors `coerce_witness`); a generic fn
with a concrete value-struct param/return emitted unboxed (now gated on `generic_count`); a non-flat
struct as an enum payload (silent corruption → clean error); a `mut self` interface used as `dyn` (runtime
panic → clean error at the upcast); value-struct args to closure/dyn/bound calls (now boxed). Verified by
the full suite (292 green) + tests/native/heap_struct.em + struct_box_bridge.em + a 13-case RSS leak sweep
(structs-with-strings, field reassign, concat, interpolation, interfaces, param-concat, `==`, closures,
`?`, field-return, bounded generics, dyn dispatch, and an all-features mega-stress). Remaining: extend the
differential harness to MEASURE RSS so leak regressions are caught automatically (follow-on); a niche
type-param/struct name collision spun out as OFI-053.

### OFI-041 — No wrapping integer arithmetic (hashes/PRNGs that need wrap-multiply aren't writable) — CLOSED
*Opened 2026-06-15 (adding bitwise/shift); closed 2026-06-15 (Karl chose function builtins over operators).*

Ember's `+ - *` **trap on overflow** (OFI-005 — the right default), but hashes/PRNGs/checksums
*depend* on modular (2^width) arithmetic, so they couldn't be written in pure Ember. **Fixed** by
adding three explicit builtins — `wrapping_add`/`wrapping_sub`/`wrapping_mul(a, b)` — that wrap instead
of trapping (Karl's call: **function form**, not `&*`-style operators, to avoid new sigils + the
`>>`-style precedence/lexer churn, and to keep wrapping unmistakably explicit like `move`). They take
two same-width integers, return that width, and compute modulo 2^width (two's-complement for signed)
via new `OP_WRAP_ADD/SUB/MUL` opcodes (uint64 arithmetic then truncate+reinterpret per the operand's
numeric kind — no overflow trap). Trapping `+ - *` stays the default; there is no wrapping `/`/`%`.
Checker special-case mirrors `to_int`/`len` (no grammar change); codegen pushes both operands + the
kind byte. **Showcase + regression:** FNV-1a in pure Ember — `tests/run/wrapping_arith.em`,
`fnv1a("hello") == 1335831723` (the canonical value), plus u8/u16/i8 wrap cases. 260 green. Docs:
language.md numerics + an architecture.md decision. **Follow-up left open (optional, not bundled):**
`std/map` still hashes built-in keys through the native `hash()` shim (the witness layer, not
`std/map.em`); rewiring built-in-key Hash witnesses to pure-Ember hashing is now *possible* but is a
witness-layer change with regression risk on the `Map` campaign — deferred as internal cleanup with no
user-visible payoff (the C hash works fine).

### OFI-002 — Generic struct literal vs. less-than is resolved by a lookahead heuristic — CLOSED
*Opened 2026-06-10 (while building the expression parser); closed 2026-06-15 (decision: keep the clean syntax, prove the rule).*

`Name<T> { … }` (a generic struct literal) and `name < x` (a comparison) share the `<` prefix.
Decision (Karl's call, 2026-06-15): **keep the clean `Name<T> { … }` form — NO turbofish.** Turbofish
(`Name::<T>{}`) is exactly the Rust syntax the LLM-first manifesto exists to avoid, and it buys a
disambiguation the grammar doesn't need. Instead the lookahead was **proven sound and hardened** from
a heuristic into a decision rule. Two grammar facts make it total: (1) **no expression begins with
`{`** — `parse_primary` ([src/parser.c](src/parser.c)) has no `TOK_LBRACE` case, so a `> {` sequence
can never continue a comparison; and (2) a type-argument list contains **only** the tokens
`parse_type` can consume. `looks_like_generic_struct_lit_from` now accepts the form iff every token
between the angle brackets is type-legal (new `type_arg_token` helper — ident/`.`/`,`/`[`/`]`/`fn`/
`(`/`)`/`->`, plus nested `<`/`>`) AND the balanced `>` is immediately followed by `{`; any other
token (a literal, an operator, a newline) proves the `<` is a comparison and bails. False positives on
well-formed types are therefore impossible, and a malformed type-ish span yields a parse error in
`parse_type`, never a silent miscompile. (Also: no `<<`/`>>` shift operators exist and `<=`/`>=` are
distinct tokens, so nested generics `Vec<Vec<int>>` and comparisons never confuse the depth scan.)
**LOAD-BEARING INVARIANT, now documented in `docs/grammar.ebnf` note (G) + `docs/language.md`:** the
rule rests on "no expression begins with `{`"; any future brace-initial expression (map/record literal,
block-expression) reopens this OFI by design. The `no_struct` suppression in if/for/match headers is
specified in grammar note (S). Regression: `tests/run/generic_literal_vs_lt.em` (both readings side by
side incl. the comma-spanning `pick(a < b, Box<int>{…})` case). 245 green.

### OFI-040 — `make install` SIGKILLed the LSP via macOS code-sign cache (cp-in-place reused the inode) — CLOSED
*Opened & closed 2026-06-15 (surfaced while fixing OFI-039: after `make install` the VS Code hover was STILL blank).*

After fixing OFI-039 and running `make install`, hover was still dead in the editor. The cause was
unrelated to hover: `editors/vscode/extension.js` launches `$(PREFIX)/bin/emberc --lsp` (the
*installed* binary at `~/.ember/bin/emberc`), not `build/emberc`. The install target did
`cp $(RELEASE_BIN) "$(PREFIX)/bin/emberc"` **over the existing file**, which keeps the destination's
inode. On arm64 macOS the kernel caches a Mach-O's ad-hoc code signature (cdhash) **per inode**; the
new content's cdhash no longer matched the cached one, so the kernel SIGKILLed the process on exec
("Killed: 9", exit 137). The launched language server died instantly and silently — VS Code just
showed nothing, looking exactly like the hover bug was unfixed. Proof: byte-identical binary ran fine
from `build/` (fresh inode) but was killed from `~/.ember/bin/` (overwritten inode); `rm`-then-`cp`
(new inode) ran clean. **Resolution:** `make install` now `rm -f`s the destination binary before
copying, so each install lands on a fresh inode with a fresh signature. (Same hazard hit the VS Code
extension install historically — see the `install-vscode` comment.) Verified: `make install` →
installed binary runs `--lsp` (exit 0) and serves the `send<T>` card.

### OFI-039 — LSP hover returned nothing on the channel builtins (`channel`/`send`/`recv`/`close`) — CLOSED
*Opened & closed 2026-06-15 (user-reported: hovering `send` and `close` in `examples/05_concurrency.em` gave no popup).*

Sibling of OFI-038, but for free-function builtins rather than methods. The channel operations
`channel`/`send`/`recv`/`close` are special-cased by name in `check_call` (`src/check.c`) and were
never registered anywhere else — in particular they were **absent from `include/vocab.def`**, the
single source of truth that drives both `hover_markdown`'s `g_builtin_docs` table (`src/lsp.c`) and
the editor-asset highlighter (`tools/gen_editor_assets.c`). So `hover_markdown` found no `DocCard`
and returned 0 (no popup), and the same names weren't highlighted as builtins. The concurrency
*keywords* `nursery`/`spawn` hovered fine (they go through `keyword_doc`), which made the gap look
arbitrary. **Resolution:** added four `EMBER_BUILTIN` entries (generic over the element type `T`:
`fn send<T>(ch: Channel<T>, value: T)` etc.) to `vocab.def`, mirroring the signatures the checker
already enforces. Hover, completion, and syntax highlighting all pick them up from the one source;
regenerated `editors/vscode/syntaxes/ember.tmLanguage.json` (OFI-033 drift check). Verified:
`tests/run-lsp.sh` now asserts all four cards; 244 green.

### OFI-038 — LSP hover returned nothing on built-in array/string methods (`a.append`, `s.split`, …) — CLOSED
*Opened & closed 2026-06-15 (user-reported: hovering `tokens.append(…)` in `examples/06_calculator.em` gave no popup).*

`handle_hover` (`src/lsp.c`) answers a member identifier from the semantic index, which the checker
fills via `sem_record_method` — but **only for user-defined struct methods** resolved through the
method table. The built-in array methods (`append`/`remove_last`/`len`) and string methods
(`len`/`chars`/`split`/`parse_int`) are special-cased earlier in `check_call` (`src/check.c`) and
returned their result type **without recording any index entry**, so `semindex_lookup` at the method
name found nothing and the AST/vocab fallback (`hover_markdown`) — which only knows top-level decls,
builtin free-functions, type names, and keywords — couldn't rescue a bare member name either. Result:
*every* dot-notated native method had a blank hover, which looked like "all methods are broken"
because `06_calculator.em` only ever calls intrinsics. **Resolution:** new `sem_record_intrinsic`
(`src/check.c`) logs an `SK_METHOD` entry at the method-name span for each intrinsic branch, with a
one-line signature rendered from the receiver/parameter/return `SemType`s through the same
`render_type` the rest of the index uses (so the card matches a real method's surface syntax) and the
receiver type as the container. No def site is recorded — the methods are native, so go-to-definition
stays a deliberate no-op. Verified: `tests/run-lsp.sh` now asserts the `.append`/`.len`/`.split`
cards; 244 green; crash-regression sweep clean.

### OFI-037 — `new_type` did not zero AST type nodes → uninitialised `qualifier` crashed the LSP — CLOSED
*Opened & closed 2026-06-14 (found from a user-reported "Ember Language Server crashed 5 times" loop).*

Arena memory is not zeroed, and `new_type` (`src/parser.c`) set only `kind`/`line`/`col`, leaving the
per-kind `as.*` union as recycled garbage. The bare struct-literal paths (`Point { … }`,
`Point<T> { … }`) set `as.name.name`/`as.generic.name` but **not** the optional `as.*.qualifier`. On a
fresh arena that slot reads `NULL` (fine), but in the long-lived language server the arena hands back
*dirty* memory after enough requests, so `qualifier` became a garbage non-NULL pointer →
`annotation_type` (`src/check.c`) took the module-qualified branch and `strcmp`'d a wild pointer →
SIGSEGV. Same uninitialised-arena-node class as OFI-026 (`new_expr`). **Resolution:** `new_type` now
`memset`s the whole node to 0 before setting fields, killing the class (not just `qualifier`).
Verified: a position sweep of `examples/09_ui.em` over the LSP, which SIGSEGV'd around request ~2365,
now completes clean; new `run-lsp.sh` crash-regression catches a revert. See also OFI-036.

### OFI-036 — `Checker.global_count` left uninitialised → LSP wrote `globals[garbage]` — CLOSED
*Opened & closed 2026-06-14 (found while chasing the same LSP crash loop as OFI-037).*

`check_program` (`src/check.c`) zero-initialises every Checker counter (`fn_count`, `struct_count`,
`enum_count`, …) **except `global_count`**. In a one-shot batch compile the stack slot happens to be
0; but the language server runs `check_program` thousands of times in one process, so a stale value
persisted on the stack. `collect_global` then did `int g = c->global_count++; c->globals[g] = …` with
a garbage (often negative) index → out-of-bounds write → crash. Only files whose modules declare
top-level `let` constants reached `collect_global`, which is why crashes clustered on the std-importing
examples. **Resolution:** added `c.global_count = 0;` alongside the other counters. Fixing this alone
moved the crash deeper (the process got ~790 requests further) and exposed OFI-037; both were needed.

### OFI-035 — LSP advertised a `.` completion trigger but returned the global symbol list — CLOSED
*Opened & closed 2026-06-14 (flagged while planning the LSP roadmap; fixed in Phase 2b).*

`initialize` advertised `completionProvider.triggerCharacters: ["."]`, so editors fired a completion
request the moment the user typed `receiver.` — but `handle_completion` was context-insensitive and
answered with *every top-level symbol plus all keywords*. After a dot that is both wrong and noisy:
the only valid completions there are the receiver's members. **Resolution (Phase 2b):** added
`complete_members` (`src/lsp.c`), tried first in `handle_completion`. It detects a `name.` context
from the token stream (`member_receiver`), resolves the receiver's type from the semantic index
(OFI's sibling, the Phase 2a index), finds that type's declaration in the parsed AST, and offers its
fields + methods (struct) or variants (enum) — each with an `ember`-fenced detail and its `///` doc.
A member context now ALWAYS returns members (an empty list if the type can't be resolved), so it
never falls back to globals. Verified by a new run-lsp.sh assertion: `p.` (p: Point) offers `x`/`y`/
`dist2` with Field/Method kinds and leaks no globals/keywords. Limitation (noted): only a bare
identifier (or `self`) receiver resolves; chained `a.b.` waits on field-type recording (Phase 2b+).

### OFI-034 — Surface type/signature formatting duplicated across lsp.c and docgen.c — CLOSED
*Opened 2026-06-14 (while building `--emit=docs`); closed 2026-06-14.*

Rendering a `Type` to its surface form ("`[T]`", "`Box<int>`", "`fn(int) -> bool`") and a `FnDecl`
to its signature ("`fn name(a: int) -> int`") was hand-written, byte-for-byte identical, in the LSP
hover/completion formatter (`type_str`/`fn_sig` in `src/lsp.c`, writing to a `JsonBuf`) and the docs
generator (`fmt_type`/`fmt_fn_sig` in `src/docgen.c`, writing to a `FILE*`) — they diverged only in
their output sink. A growth in type syntax (tuples, `?`-nullable, …) would have to touch both or the
editor tooltip and the generated docs would quietly disagree. **Resolution:** one shared formatter
`src/typefmt.c` (`typefmt_type`/`typefmt_fn`) over a tiny `TypeSink { put; ctx }` abstraction; lsp.c
and docgen.c now keep thin wrappers that supply a JsonBuf- or FILE*-backed sink and delegate. Output
is byte-identical (docs golden unchanged, LSP regression green, 244 default green). **Scoped down
deliberately:** two *related* renderers were left out by design, not oversight — `src/ast_print.c`'s
`print_type` is a **debug AST dump** with its own conventions (golden-locked, no qualifier, `<none>`
for unit), and `src/check.c`'s `render_type` formats a resolved `SemType` id, a *different input
domain* that can't share an AST-`Type *` traversal. Folding either in would change debug output or
fight the type system for no gain. typefmt.h documents both exclusions so a future reader doesn't
"re-unify" them.

### OFI-033 — Language vocabulary duplicated across lexer / LSP / TextMate grammar (drift risk) — CLOSED
*Opened & closed 2026-06-14 (raised while planning LSP maintenance; Karl flagged the maintenance-drift risk).*

The set of keywords, builtins, and primitive types — Ember's lexical vocabulary — was copied by
hand into **four** independent places: the lexer's `KEYWORDS[]` table (the only canonical one),
the LSP's `keyword_doc()` glosses + `handle_completion` keyword list + `g_builtin_docs[]`/`g_type_docs[]`
cards (`src/lsp.c`), and the TextMate grammar's keyword/builtin/primitive alternations
(`editors/vscode/syntaxes/ember.tmLanguage.json`). Adding one keyword meant editing four files,
three of them pure derived copies; the comment at `src/lsp.c` even admits it hand-mirrors check.c's
signatures "so hover never drifts". OFI-032's resolution claimed the grammar was "generated from the
real lexer tables" — it was not; this OFI makes that claim true. **Plan (agreed 2026-06-14):** one
X-macro single source of truth `src/vocab.def` that `lexer.c` + `lsp.c` `#include` (so those three
consumers *compile* from the same bytes — they cannot drift), plus a build-time-only generator
`tools/gen_editor_assets.c` that emits the whole TextMate grammar from the same table, gated by a
`make check-editor-sync` target (regenerate + `diff`, fail the build if stale). Rule established:
`emberc` = what users/editors run; `tools/` = what language developers run to maintain checked-in
artifacts (so the generator is a standalone tool, not an `emberc --emit` mode — `--emit` transforms a
user program, this dumps language metadata). **Resolution:** `include/vocab.def` is now the single
source of truth — `src/lexer.c` (`KEYWORDS[]`), `src/lsp.c` (`keyword_doc()`, completion list,
`g_builtin_docs[]`, `g_type_docs[]`) all `#include` it via X-macros, so those three *compile* from the
same bytes and cannot drift. `tools/gen_editor_assets.c` emits the whole TextMate grammar from the
same table (structural rules authored in the tool, since strict-JSON grammars can't carry comment
fences); it reproduced the previous hand-written grammar byte-identically. `make gen-editor-assets`
regenerates in place; `make check-editor-sync` (now run by `make test`) regenerates and diffs, failing
the build if the committed grammar is stale. Adding a keyword/builtin/primitive is now a one-line
`vocab.def` edit + regenerate. 243 green, LSP regression green, grammar byte-identical. `editors/vscode/
README.md` documents the generated-not-hand-edited workflow.

### OFI-032 — VS Code extension lived only in `~/.vscode` (un-versioned) + had no syntax highlighting — CLOSED
*Opened & closed 2026-06-14 (found while diagnosing "no colours in .em files").*

The VS Code client written last session was placed *directly* in `~/.vscode/extensions/ember-lang`
and never committed to the repo; `make install` deployed only the binary + std, so the extension
glue (`extension.js`, manifest, `language-configuration.json`) was an un-tracked liability with no
history — lost on any dir wipe or machine move. Separately, the manifest had **no `grammars`
contribution**, so VS Code had no TextMate grammar and `.em` files got zero syntax colouring
(coloring is a TextMate grammar, wholly independent of the LSP — the LSP itself was verified
healthy: `initialize` returns hover/definition/completion/documentSymbol). **Resolution:** the
canonical extension source now lives in `editors/vscode/` (glue + `syntaxes/ember.tmLanguage.json`,
a grammar generated from the real lexer keyword/type/builtin tables — keywords, primitive + sized
numeric types, strings with `\` escapes and `{…}` interpolation holes, `requires`/`ensures`
contracts, builtins, numbers, operators). A new `make install-vscode` target deploys it to
`~/.vscode/extensions/ember-lang` (which keeps the extension GLOBAL — it colours any `.em` file
system-wide, repo-membership irrelevant). README in `editors/vscode/` documents the
highlighting-vs-LSP split and the install/reload flow.

### OFI-031 — A whole nested struct field can't be read out by value (partial move) — CLOSED
*Opened & closed 2026-06-14 (value-types 3b.5 — inline nested struct fields).*

Reading a *whole* nested struct field out, `let p = ln.a`, was rejected ("cannot move a value out
of a field — partial moves are not supported") because a boxed nested field was a unique-owner
pointer that binding-out would alias. **Resolution (3b.5):** an all-scalar nested struct field is
now stored INLINE — its packed bytes embed in the parent's buffer (no separate heap object), and
reading it out materialises a value COPY (exactly how `arr[i]` became a copy in 3a.1). So `let p =
ln.a` is a copy (the source stays valid, the copy is independent), a nested assignment path
`c.b.a.v = …` writes back through the inline fields (materialise-modify-writeback in codegen), and
nested construction packs the field bytes inline. New checker `nested_inline_sid` (recursive: every
field scalar or inline-able struct), recursive `field_storage_size`, `StructType.field_struct[]`
(the nested type id per inline field), and VM GET/SET_FIELD + NEW_STRUCT handle the inline bytes
(reusing the AEK_INLINE_STRUCT array machinery). Tests nested_struct.em (=>26), field_mutation_nested.em,
nested_struct_value.em (=>179, copy-independence + 3-level write-back). 226 green, RSS flat over a
mutation loop, parallel parity. LIMIT: the *parent* of an inline field stays BOXED for now (not yet
multi-slot — so `var dup = copyOfB` still moves rather than copies); transitive multi-slot is the
next step. All-scalar nested only (a refcounted sub-field needs recursive retain/release — later).

### OFI-030 — Example programs 03_errors / 05_concurrency don't fully compile (stale APIs) — CLOSED
*Opened 2026-06-14; closed 2026-06-14.*

`tests/run.sh` only **smoke-tested** examples (lex + parse), so two flagship examples had
drifted from the implemented language without anyone noticing: `examples/03_errors.em` used
`read_file(path)?` (read_file isn't a `Result`, so `?` is rejected) and undefined helpers
`parse_host`/`parse_port`; `examples/05_concurrency.em` called undefined `contains(...)` /
`read_chunks(...)` / `dispatch(...)` / `drain(...)`. Neither was a compiler bug — stale showcase
code. **Resolution, both halves (the rewrite alone would let it re-rot):**
1. **Rewrote both examples against the real stdlib.** `03_errors.em` now showcases `?` through a
   genuine `Result`-returning `field`/`parse_host`/`parse_port`/`load_config` chain over a config
   blob (built-in `.split`/`.parse_int`, `std/string.trim`), exercising both the Ok and the
   short-circuit Err path; `05_concurrency.em` is a real worker-pool — a `dispatch` task feeds
   `[string]` chunks onto a typed `channel(200)` and `close`s it, four `worker`s fan out and tally
   ERROR lines (`std/string.contains`) onto a results channel, `main` drains and sums. Both compile
   AND run (`serving example.com:8080` / `config error: missing field: port` / `found ada`;
   `total ERROR lines: 3`).
2. **Killed the drift class.** The smoke tier in `tests/run.sh` now FULL-compiles every example
   (`--emit=bytecode`, i.e. type-check + codegen), not just lex+parse; the graphics examples
   (importing `std/draw`/`std/ui`, which need the raylib natives the dependency-free build lacks)
   stay lex+parse there and are full-compiled in `tests/run-graphics.sh` under `emberc-gfx`. So a
   showcase example can no longer silently drift off the language — exactly the gap that let this
   happen. 244 green.

### OFI-029 — No return-path analysis: falling off a non-unit function yields a garbage value — CLOSED
*Opened & closed 2026-06-14 (landing value-types 3b.4b, multi-slot struct returns).*

A function declared `-> T` that failed to `return` on some path was NOT rejected; codegen's
fall-off safety net emitted an implicit `return 0` (a zero-filled multi-slot value for a
struct return). E.g. `fn maybe(c: bool) -> Pt { if c { return Pt{1,2} } }` compiled, and
`maybe(false)` yielded `Pt{0,0}` — a silently-wrong value. **Resolution:** added
**definite-return analysis** in the checker ([src/check.c](src/check.c) `block_returns`/`stmt_returns`,
applied in `check_callable`): a non-unit function whose body does not return on every path is
a compile error. The analysis recognises `return`, both arms of an `if/else`, all arms of an
(exhaustive, checker-enforced) `match`, and an infinite `loop` with no exiting `break` as
guaranteed exits (`loop_exit_break` walks the body, skipping nested loops/for). The codegen
fall-off `return 0` is now dead (kept only as a halt guarantee). 222 green with zero false
positives — every existing function already returns on all paths. Test `error_missing_return.em`.

### OFI-028 — A copy-type (all-scalar struct) borrow parameter can't be returned by value — CLOSED
*Opened & closed 2026-06-14 (landing value-types 3b.4a, multi-slot struct parameters).*

`fn echo(p: Pt) -> Pt { return p }` was rejected with *"cannot return a borrowed value — it would
escape the function; take the parameter as 'move'"*. The escaping-borrow rule is correct for a
boxed unique-owner struct (returning the borrow would alias the caller's value), but an **all-scalar
struct** is a **value type** — reading it whole already **copies** (3b: multi-slot locals/params box
on use). Returning that copy is sound: no aliasing, no double free, so the rule was too conservative
for copy-type parameters. **Resolution:** the escaping-borrow check ([src/check.c](src/check.c), STMT_RETURN)
now skips a returned value that `is_multislot_local` recognises (an all-scalar struct local/param) —
the return copies it out (box-on-use), so no reference escapes. The rule is unchanged for genuine
unique-owner move types (arrays, structs with a boxed field), verified by `error_escape_borrow.em`
(repurposed to a `string`-field struct, which still errors). New regression test
`struct_return_copy_param.em` (=>20) returns copy-type params by value and confirms the source stays
usable; it also pre-stages 3b.4b (multi-slot returns), which will change *how* the value copies out
without changing this rule. RSS flat over 2M copy-returns (no leak). 220 green.

### OFI-027 — Transient owned-struct temporaries leak (never dropped) — CLOSED
*Opened & closed 2026-06-13 (grounding the value-types inline-array storage switch).*

A fresh owned struct produced by a call/construction and used **transiently** — as the object of a
field access or method receiver, then discarded — is never freed. `acc = acc + mk(i).x` in a 5M-iteration
loop (where `mk` returns a struct) grows RSS to **405 MB**; the same loop binding the result
(`let p = mk(i)`) stays flat at **1.97 MB** (dropped at scope exit). So the leak is specifically the
*transient* path: `OP_GET_FIELD` (and method-receiver / borrow-arg use) reads from a fresh owned
struct on the stack but nothing drops the struct afterward. `is_owning_temp` ([src/check.c](src/check.c))
only recognises *refcounted* temporaries (string/enum/closure) — a struct isn't refcounted (it's a
unique owner freed by `OP_DROP`), so `STMT_EXPR` does `OP_POP` (not `OP_DROP`) and a sub-expression
struct temp is never marked for drop at all. Pre-existing (not introduced by recent work); latent
because struct results are usually *bound* (then dropped at scope exit) or *returned* (moved out) —
the transient-discard pattern is the unlucky path.

**Why it matters now / blocks value-types:** the approved design for inline struct arrays makes
`arr[i]` a value **copy** (a materialised owned struct temporary), used transiently in `arr[i].field`,
`sum(arr[i])`, etc. Those copies would hit exactly this leak. So fixing owned-struct-temporary cleanup
is the prerequisite before inline-array storage — and it's foundational for the whole language.

Measured surface (5M-iter loops, each ~386 MB before): (a) discard `make(i)`; (b) field-object
`make(i).x`; (c) method-receiver `make(i).m()`; (d) borrow-arg `sum(make(i))`. Refcounted temps
(string/enum) DON'T leak at these sites: the callee releases refcounted borrow params at exit
(`Param.release_at_exit`), and a fresh refcounted temp has refcount 1 so the callee's release frees
it. A struct has no refcount, so the callee can't release a borrow without freeing the caller's owned
struct — therefore the **caller** must drop struct temps.

**PROGRESS:**
- **(a) discard — FIXED 2026-06-13.** `is_owning_temp` ([src/check.c](src/check.c)) now returns true
  for fresh owned MOVE-types (struct/array), not only refcounted; `STMT_EXPR`'s `OP_RELEASE` runs
  `drop_value`, which frees a struct directly. `make(i)` discard loop 386 MB → **2 MB**; 215 green
  (no double-free: place-reads/locals are still excluded, so only fresh sole-owner temps drop). Match
  subjects are always enums, so unaffected.
- **(b) field-object — FIXED 2026-06-13.** New `OP_GET_FIELD_OWNED` (opcode.h) + `get.drop_object`
  flag (ast.h), set by the checker when the field-access object is a fresh owned temp
  (`is_owning_temp(object)`). The VM op reads the field, RETAINS it if boxed (transferring the
  receiver's reference so it survives), then `drop_value`s the receiver. `make(i).x` loop 386 MB →
  **2 MB**; boxed-field correctness verified (`mk(7).label.len()` = 5, no use-after-free). Re-blessed
  `tests/codegen/bounded.bytecode` (`max(lo,hi).n` now drops the returned temp — a real leak it had).
  215 green.
- **(c) method-receiver + (d) borrow-arg-at-position-0 — FIXED 2026-06-13.** New `OP_DROP_UNDER`
  (drop the value just below the top, keep the result) + a `DUP` of the temp before the call. The
  checker sets `call.drop_first` when the FIRST pushed call value — arg0 of a direct call, or a
  method's receiver — is a fresh owned struct temp passed by borrow (`is_owning_temp`, and the param
  isn't `move`; for a method, `self_qual != move`, via a new `MethodInfo.self_qual`). Codegen DUPs it
  after pushing (so a copy sits under the args, directly below the result) and `OP_DROP_UNDER`s after
  the call. `make(i).s()` and `sum(make(i))` loops 386 MB → **2 MB**. CORRECTNESS verified by a 3M-iter
  mixed-pattern checksum (borrowed locals reused after calls, temps as arg/receiver/field, `move`
  params, `move self`, discards): deterministic result, **RSS flat at 2 MB, no double-free**. 215 green.

- **multi-arg / non-first-arg / method-arg — FIXED 2026-06-13 (the general case).** Generalised
  `drop_first` to a `call.drop_mask` (bit per borrow-temp arg, any position/count) plus a new
  `OP_PICK n` (push a copy of the value n-below-top). Codegen evaluates the marked temps FIRST (their
  kept copies sit at the bottom, in source order), builds the args in order (a temp re-fetched as a
  borrow alias via `OP_PICK`, a non-temp freshly), calls, then `OP_DROP_UNDER`×N. Applied to direct
  calls AND struct-method calls (receiver + args; `MethodInfo.quals` added so a `move` method-param
  arg isn't dropped). Witness (bounded-generic) calls fall back (rare). Eval-order note: a fresh
  temp arg is evaluated slightly early — observably equivalent in Ember (no mutable globals; value
  semantics), and identical to writing `let _t = mk()`. `foo(a,mk())`, `foo(mk(),mk())`,
  `base.add(mk())` all 233 MB → **2 MB**.

**RESOLUTION:** all seven transient shapes — (a) discard, (b) field-object, (c) method-receiver,
(d) borrow-arg, (e) non-first arg, (f) multiple temp args, (g) method-arg — now reclaim the temp,
386/233 MB → **2 MB** each. Verified by a 4M-iteration mixed-pattern checksum (reused locals after
borrows, `move` params, `move self`, every transient shape): **deterministic result, RSS flat,
no double-free**. New primitives: `OP_GET_FIELD_OWNED`, `OP_DROP_UNDER`, `OP_PICK`; the checker marks
fresh owned-temps in borrowing positions (`get.drop_object`, `call.drop_first`, `call.drop_mask`),
guarded by param/self qualifiers so `move` targets (callee-owned) are never double-dropped.
Regression `tests/run/struct_temp_drop.em`; 216 green. The value-types inline-array storage switch
(the original goal) now has a leak-free foundation.

### OFI-026 — Uninitialised AST node field corrupted call resolution (surfaced via unit `ensures`) — CLOSED
*Opened & closed 2026-06-13 (building contracts on UI state; root-caused next session).*

Allowing `ensures` on a void `mut self` mutator (a state-invariant postcondition like `fn begin(mut
self) ensures self.cx == self.style.pad`) made the build fail with codegen *"unresolved identifier"*
on `concat`/`substring` calls inside **`std/string`** — an *unrelated* module. It worked
single-module but not in the real `std/draw`+`std/ui`+`std/string`+main graph, and reverting the
checker change alone hid it — which pointed (wrongly) at a contract-checking bug. **Real root cause:
an uninitialised field.** `new_expr` ([src/parser.c](src/parser.c)) allocated `Expr` nodes from the
arena (which does *not* zero memory) and set only a few common fields; the call node's
**`closure_call`** flag was never initialised at its creation site. It was *usually* 0 by luck, but
adding `begin`'s `ensures` shifted the parse-time allocation pattern so the garbage in some
`std/string` call nodes became `8` — truthy — making codegen take the function-value path
(`gen_expr` the callee) instead of the direct call, so `substring`/`concat` hit the bare-identifier
codegen and failed. Found by instrumenting codegen: `DBG call 'substring' … closure_call=8
resolved_fn=45` (a valid index 45, but `closure_call=8` overrode it). **Fix:** `new_expr` now
`memset`s the whole node to 0 before setting `kind`/`line`/`col`; explicit non-zero defaults
(`resolved_fn = -1`, since 0 is a valid fn index) still override at each creation site. This kills
the entire class of uninitialised-`as.*`-field bugs, not just this instance. Unit-method `ensures`
re-enabled (checker allows it without binding `result`; codegen runs the checks at the implicit
end-of-body return). `std/ui.begin` now carries its frame-start invariant (`hot == NONE`, cursor at
margin, `cur_win == NONE`); a unit-method postcondition violation emits a structured
`contract_violation` on the tape. Regression `tests/run/unit_method_ensures.em` (=>5); 215 green,
graphics 4/0.

### OFI-025 — `std/ui` windows are fixed-size; content isn't clipped to the window rect — CLOSED
*Opened & closed 2026-06-13 (building Phase B overlapping windows).*

A window (`window_begin`, [std/ui.em](std/ui.em)) was registered at a fixed 220×180 and never fit
its widgets, and there was **no clipping** — content that overflowed drew *past* the window rect
over neighbours, because the deferred buffer had only ordered rects/text. **Fixed, both halves
(they depend on each other — clipping alone would just hide widgets, auto-size alone could still
bleed during the resize lag):**
1. **Clipping** — added a `GCMD_CLIP_PUSH`/`GCMD_CLIP_POP` pair to the deferred command buffer
   ([src/graphics.c](src/graphics.c)), driven by new natives `clip_push(x,y,w,h)`/`clip_pop()`
   (ids 115/116, full plumbing). At flush the renderer keeps a small scissor stack and **nests by
   intersection** (a clip inside a clip is the overlap → scroll regions later compose), mapping to
   raylib `BeginScissorMode`/`EndScissorMode`. Because a window's commands share one layer and stay
   contiguous through the stable sort, each push/pop pair stays paired and ordered; a defensive
   `EndScissorMode` guards an unbalanced push. `window_begin` clips content to the body
   (`wx, wy+bar_h, ww, wh-bar_h`); `window_end` pops.
2. **Auto-size** — `advance` records each window's content extent (`content_x/content_y`) while
   `cur_win` is set; `window_end` sets the window's `w/h` to fit (never narrower than the title),
   applied next frame (the same last-frame trick input routing uses, and it converges in one frame).
   Verified by `tests/graphics/windows.em`: an empty window collapses to its title bar
   (`bar_h + 2·pad = 48`), a one-label window fits one row (`80`). `make test-graphics` green.
Remaining (deferred, not blocking): a user resize grip, and scroll regions (now unblocked by the
clip — a scroll region is a clip plus a content offset).

### OFI-024 — A brand-new window can't receive input on its first frame — CLOSED (WONTFIX)
*Opened & closed 2026-06-13 (building Phase B overlapping windows).*

Input routing decides which window is under the mouse from **last frame's** geometry (begin(),
[std/ui.em](std/ui.em)) — the standard immediate-mode trick, since this frame's window rects
aren't known until `window_begin` runs. So a window created this frame isn't in the registry when
`begin` computes `hover_win`, and can't be clicked/focused until the *next* frame. In practice
windows are rebuilt every frame from persistent state, making this a one-frame (~16ms) latency on a
window's *very first appearance only* — below human perception (reaction time is ~6 frames) and
exactly how Dear ImGui behaves. **Decided WONTFIX:** the only real fix is a two-pass frame
(describe all windows, then route input), which trades the model's defining simplicity for a
benefit no user can perceive. The cheap inline alternative (upgrade `hover_win` mid-frame when a
new top-z window is under the mouse) adds order-dependent state to the per-frame hot path and a
transient mis-engage of a background widget — net negative. Left as-is by design.

### OFI-023 — Top-level `let` constants + cross-module qualified value access — CLOSED
*Opened & closed 2026-06-13 (surfaced building `std/draw` for the graphics spike).*

A top-level `let NAME = <literal>` was parsed but rejected ("only function, struct, enum,
interface declarations…"), so a module couldn't export named constants — `std/draw` had to expose
colors/keys as zero-arg functions (`draw.red()`) instead of `draw.RED`. **Fixed via compile-time
substitution** ([src/check.c](src/check.c)): a top-level `let` with a *literal* initializer (int,
float, bool, string, or unary-minus literal) is collected as a named **constant** of its module
(`collect_global`); a bare use (`resolve_global`) or a qualified use (`resolve_qualified_const`,
mirroring `resolve_qualified_fn`) is **rewritten in place into a copy of the literal**
(`substitute_const`), so there is *zero* runtime/codegen/VM change — the constant simply isn't a
runtime entity. This also added **cross-module qualified *value* access** `mod.NAME` (only
qualified calls/types resolved before; `draw.RED` had errored "undefined variable"), handled in
the EXPR_GET checker alongside the `Enum.Variant` case, with module privacy (`_name`) enforced.
`std/draw` now exposes `draw.RED`/`draw.RIGHT` etc.; the demo reads naturally. Tests
`tests/run/global_const.em` (=>400) + `error_global_non_literal.em`; 211 green, parallel parity.
**Scope:** literal `let` constants only — a non-literal initializer (`let X = f()`) and a top-level
`var` are rejected with a clear message. General runtime-initialized/mutable globals (any
expression, `var`) remain deliberate future work; named compile-time constants are the complete,
common case (colors, key codes, limits, config) and what `std/ui` will want.

### OFI-022 — Lexer errors bypass the diagnostics layer (absent from `--diagnostics=json`) — CLOSED
*Opened 2026-06-13 (while building structured diagnostics); closed 2026-06-15.*

Type errors (`type_error`, [src/check.c](src/check.c)) and parser errors (`error_at`,
[src/parser.c](src/parser.c)) flowed through `diag_error` ([src/diag.h](include/diag.h)), so they
render either as human text or — under `--diagnostics=json` — as structured JSON. The **lexer** did
not: it only emitted a bare `TOK_ERROR` token + set `had_error`, producing **no** `file:line:col:
error:` line in *either* mode (the OFI's "inline `fprintf`" framing was already stale — there wasn't
even a message), so a purely lexical error (unterminated string, stray `$`, lone `&`) was invisible
to the machine-readable stream and nearly invisible to humans (only a downstream parser-cascade
error showed). **Resolution:** the Scanner now carries the source-file name (threaded through
`lexer_scan(source, source_name)` — all six call sites updated: main entry, imported modules,
`<prelude>`, the interpolation-hole sub-lexer, and the three LSP entry points), and a central
`lex_error` helper routes each of the three lexical-error sites through `diag_error` with a teacher-
grade message + help (`unterminated string literal` → "add a closing `\"`"; lone `&` → "use `&&`
for logical and (MANIFESTO §5b)"; stray byte → `unexpected character (near 'X')`). The `TOK_ERROR`
token + `had_error` flow is unchanged, so recovery/exit-code behaviour is identical — diagnostics
are now *additionally* reported. Both modes verified: human prints the `error:`/`help:` lines, and
`--diagnostics=json` emits one JSON object per lexical error (was zero). The existing
`tests/lexer/errors_recovery.em` (which exercises all three sites in one pass) is the regression
guard — its golden now carries the three reported errors; revert the routing and it fails. 244 green.

### OFI-021 — `--emit=bytecode` disassembly mislabels function names in large programs — CLOSED
*Opened 2026-06-13 (noticed while debugging OFI-007); closed 2026-06-15 (verified resolved by OFI-007).*

Disassembling a program with a few hundred functions printed wrong `== fn NAME ==` headers
(e.g. every function labelled `f1`, and the final function — actually `main` — shown as `f9`),
and `grep` for `CALL`/`NEW_STRUCT` in the output found nothing although the program clearly
contained them. This was opened as a *suspected separate display defect* during the OFI-007 hunt,
but it had the **same root cause**: the function-table bookkeeping in codegen — `build_mono_instances`
enumerating `fn_by_fi[MAX_FNS]` and the per-slot name/offset mapping — was bounded by `MAX_FNS`
(256), so entries past 255 (and `main` when methods interleave before it) got the wrong name and a
desynced chunk offset, which is exactly what made the disassembler print garbage headers and lose the
opcodes. OFI-007's fix (size that enumeration by the true `free-functions + methods` total, 16-bit
call index) corrected the same bookkeeping the disassembler reads. **Resolution — verified, not
assumed:** a fresh 281-entry program (200 distinctly-named free functions + 80 methods across 4
structs, crossing the 256 boundary) now disassembles with **281 headers, every one its real unique
name** (`free_000`…`free_199`, `W2.m_2_14`, …, `main` — zero duplicates), correct `CALL fn=0/199/200`
targets straddling the boundary, and the struct/field opcodes all present. The underlying table
bookkeeping is already runtime-guarded by `tests/run/many_functions.em` (259 entries, `main` + a
called method both past 255) — if it ever re-desyncs, that test fails at execution. No brittle
hundreds-of-lines disasm golden added (net-negative for a debug view); the behavioural runtime guard
plus the shared-root-cause analysis is the proportionate cover.

### OFI-007 — `OP_CALL` (and the mono plan) silently miscompiled past 255 functions — CLOSED
*Opened 2026-06-10; closed 2026-06-13.*

The whole-program function table holds free functions **and** every struct method together
(methods aren't bounded by the `MAX_FNS` 256 cap — up to `MAX_STRUCTS × MAX_METHODS` slots), so a
program with >256 entries hit **two** independent silent miscompiles. **(1) `OP_CALL`/`OP_SPAWN`
carried a one-byte index** (`(uint8_t)idx`/`midx`) — index 256 wrapped to 0 and the call
dispatched to the wrong function. Fixed: widened both opcodes' index operand to 16-bit big-endian
(`emit_fn_index` in [src/codegen.c](src/codegen.c) with a `>65535` guard; the VM reads two bytes;
the disassembler ([src/chunk.c](src/chunk.c)) and the X-macro operand metadata updated to match).
**(2) The mono-plan builder** ([src/check.c](src/check.c) `build_mono_instances`) enumerated the
table into `fn_by_fi[MAX_FNS]` with a `fi < MAX_FNS` bound — so functions past index 255 (e.g.
`main` when methods are interleaved before it) were **never seeded as instances**, leaving
`main_index` at its default 0; the VM then booted the wrong function entirely. Fixed: size that
enumeration by the true `free-functions + methods` total (malloc'd), not `MAX_FNS`. **The Ember
execution tape (`--emit=trace`) found bug (2)** — it showed only `f1` running with no `CALL`,
proving the VM never entered `main`, after the disassembler's own large-program name display
misled the manual hunt (see OFI-021). Regression test `tests/run/many_functions.em` (259 table
entries; `main` and a called method both past 255; `=> 757`), identical serial and parallel. 199
green.

### OFI-019 — A nursery opened inside a nursery task crashed the serial runtime — CLOSED
*Opened & closed 2026-06-12 (found by the new `benchmarks/parallel_bench.em` nested section).*

`OP_NURSERY_END` ([src/vm.c](src/vm.c)) popped the closing nursery's group slot with
`int g = --vm->group_depth;` **before** running its tasks. The serial scheduler runs those
tasks on the *same* VM (via `run_child`), so a task that opened a **nested** nursery hit
`OP_NURSERY_BEGIN` with `group_depth` already decremented and reused slot `g` — clobbering
`vm->groups[g]`/`vm->group_sizes[g]` that the parent's scheduler loop was still iterating →
SIGSEGV. (The parallel runtime mostly dodged it because each worker gets its own VM + group
stack, but the inline-fallback path shared the latent bug.) Surfaced immediately by the
parallel benchmark's divide-and-conquer section (depth-4 nested nurseries) crashing the serial
binary while the parallel binary ran clean. **Fix:** keep the slot open while the tasks run —
`int g = vm->group_depth - 1;` up front, and `vm->group_depth = g;` only after they all finish
(both the serial and parallel branches), so a nested nursery stacks onto a deeper slot. Tasks
that open nested nurseries now work on both runtimes (same checksum). Regression test
`tests/run/nested_nursery.em` (=>2016, depth-3 divide-and-conquer). 198 green.

### OFI-017 — The parallel runtime did not detect deadlock (it hung instead of erroring) — CLOSED
*Opened & closed 2026-06-12 (M:N parallelism Stage 2b → 2b follow-up).*

The serial nursery scheduler ([src/vm.c](src/vm.c) `OP_NURSERY_END`) detects deadlock
structurally — a cooperative pass that makes no progress while tasks remain errors with
`deadlock: every task in the nursery is blocked`. The first parallel runtime (`-DEMBER_PARALLEL=1`)
blocked a stuck task on a channel **condvar** with no observer, so a genuinely deadlocked program
**hung forever** instead of producing the diagnostic. **Fixed** with a per-nursery detector
(`Nursery` in [src/vm.c](src/vm.c)): each task that blocks on a channel registers `(channel,
is_send)` in its group slot under the nursery lock; when all `total` tasks are registered, the
last one checks whether **any** of them could currently proceed (a parked receiver whose channel
has data or is closed, or a parked sender whose channel has room — the channel state is frozen
because no task is running). Only if **none** can proceed is it a true deadlock: set the flag,
broadcast every channel so the sleepers wake and error out (reported once, matching the serial
line). The readiness check (not a bare blocked-count) is essential — it mirrors the serial
scheduler's "no runnable fiber" rule and avoids a **false positive** on a signalled-but-not-yet-
woken task (caught `channel_pipe.em` mid-implementation: consumer parked on empty, producer
filled + signalled it, then parked on full → bare count hit `total` while the consumer was
actually runnable). Also fixed a self-wakeup race: a single task that detects its own deadlock
must re-test the loop condition (`continue`) before `cond_wait`, or it sleeps through its own
broadcast. Lock order is channel→nursery→heap (acyclic). `error_channel_deadlock.em` now passes
under **both** binaries → parallel run-stage is **153/153** byte-identical to serial; deadlock
fires reliably (single- and multi-task, 10/10 each, no hang) with no false positives under load
(channel_pipe 30/30, parallel_sum 15/15); ~5.0× speedup unchanged (detector is off the hot path).

### OFI-016 — A lambda capturing a `for`-loop variable or body local read the wrong slot — CLOSED
*Opened & closed 2026-06-12 (found while adding `for (i, x)` enumerate).*

Codegen lowers a `for` loop with **hidden stack slots** (the array, index, and cached length for
`for x in arr`; the index and end for a range) placed ahead of the body's locals — but the checker
declared only the loop variable, so inside a `for` body the checker's local slot numbers were
offset from codegen's by the number of hidden slots. A lambda records its captures by the
**checker's** slot numbers and codegen reads them back by the same numbers, so a closure created
inside a `for` body captured the wrong slot: `for x in xs { … |n| n + x … }` captured codegen's
*array* slot in place of `x` (a type-confused heap pointer → **SIGSEGV**), and `for i in 0..3 { let
base = …; |n| n + base + i }` silently read wrong values. Latent since closures landed (for-loops
predate them); surfaced now because enumerate touches the same machinery. **Resolution:** the
checker now reserves the identical hidden slots in the identical order (`reserve_hidden_slot`,
[src/check.c](src/check.c)) so checker and codegen slot numbering agree in lock-step. The hidden
slots use the unmatchable name `""` (no identifier is empty) so they never shadow and own nothing.
Regression test `for_enumerate.em` (=>5) captures the loop var, a body local, and the enumerate
index+element inside lambdas. 195 green.

### OFI-015 — Generic inference from array/function arguments (generic HOFs) — CLOSED
*Opened & closed 2026-06-12.*

Generic type arguments were not inferred from **array** or **function-typed** arguments
(`first<T>(xs: [T])` couldn't learn `T` from `[int]`; `fn(int)->int` didn't match `fn(T)->T`),
so generic higher-order functions didn't work and `std/list` was `[int]`-typed. **Resolution,
in five parts** ([src/check.c](src/check.c), [src/vm.c](src/vm.c)):
1. **`unify`** recurses into array element types and function param/result types.
2. **`subst`** recurses into array and `fn` types when materializing an instance.
3. **Deferred lambda arguments**: a lambda passed to a generic call is checked in a *second
   phase*, after the other arguments pin the type parameters; a still-open result parameter maps
   to itself (`fn(int) -> U`) and is then bound from the lambda's body (`TY_INFER` return mode).
4. **Qualified generic calls**: the module-qualified path's bespoke argument loop (which rejected
   generics outright) was replaced by the shared `check_fn_call` helper, so `list.map(…)` follows
   every rule a direct call does — inference, witnesses, mono key. The monomorphizer needed no
   change (it keys on `resolved_fn` + `mono_args`).
5. **Two runtime soundness holes the new power exposed**, both refcount *underflows* under
   erasure (the checker can't see that `T` is refcounted, so it emitted no retain while the
   runtime released one):
   a. A closure called inside an erased generic body (`f(xs[i])` in `map`'s body) — the lifted
      lambda's concrete params release on return. **Fix:** `OP_CALL_CLOSURE` retains heap
      arguments at run time.
   b. An erased element store (`out[j] = out[j-1]`, sort's shift) — `OP_SET_INDEX` releases the
      old element, and the stored alias carried no count. **Fix:** `consume()` marks type-param
      reads for the alias `OP_INCREF` (a runtime no-op for scalar instantiations).
   Both follow the established erased-generics convention: over-retain (a sound leak, OFI-009's
   ledger) rather than over-release (a crash). Two codegen goldens regenerated (pure INCREF
   insertions in generic bodies).
Net effect: `std/list` is now fully generic — `map<T,U>`/`filter<T>`/`reduce<T,U>`/`sort<T>` over
any element type, with capturing lambdas, via import. Tests `stdlib_list.em` (=>76, string and int
elements) and `generic_hof_strings.em` (=>60, the crash class: mixed instantiations + sources used
after the calls). Lambda capture of structs/arrays is rejected with a clear error (a by-value
capture of a unique owner would alias it — deep-copy captures are future work). 191 green.

### OFI-013 — Qualified enum-variant construction `EnumName.Variant(args)` was unsupported — CLOSED
*Opened & closed 2026-06-12.*

`Some(7)`/`None` (bare) worked everywhere, but the qualified `Option.Some(7)` / `Option.None` /
`Color.Blue(5)` failed with "undefined variable" on the enum name — in every module, so not a
scoping bug: the leading `Option` was treated as a value/`alias.member` reference, and the checker
resolved it as a bare identifier with no local. An LLM trained on Rust/Swift reaches for this form,
so for the LLM-first goal it should construct. **Resolution:** handled in the checker (not the
parser) where resolution info is available — [src/check.c](src/check.c). When the qualifier of an
`Enum.Variant` names an in-scope enum (and isn't a local or import alias), the call/get is
**desugared to the bare variant** (variant names are globally unique, so `Some` alone is
unambiguous) and flows through the existing bare-variant path; codegen is unchanged. A new
`enum_variant(eid, name)` validates the specific enum's variant set, so `Option.Nope` errors with
"no such variant on this enum" while a non-enum qualifier still gives "undefined variable". Covers
the call form (`EXPR_CALL` over `EXPR_GET`) and the zero-field form (`EXPR_GET`); bare and qualified
interoperate in one `match`. Regression test `qualified_variant.em` (Option/Result/user enum →
128). *Cross-module* `mod.Enum.Variant` (two qualifiers, imported enum) stays deferred. 185 green.

### OFI-014 — A void-returning *method* call was accepted as a value (type-check hole → crash) — CLOSED
*Opened & closed 2026-06-12 (found while converting the Map stdlib to an imported module).*

`x = f()` for a void free function `f` was correctly rejected, but the same through a **method**
(`x = c.bump()`, `fn bump(mut self)`) compiled — silently yielding a garbage value, or
**segfaulting** when the target was a heap value (a `Map<int>` used as `m = m.set("a", 2)` crashed
with SIGSEGV / exit 139), because the empty result slot was later dereferenced as that type. **Root
cause:** method signature registration set a no-annotation method's result type to `TY_ERROR` (the
error-suppression sentinel) instead of `TY_UNIT` — so the call site, which uses `mi->ret` as the
expression type, propagated `TY_ERROR`, which every value-position check accepts to avoid cascading
errors. **Resolution:** one line in [src/check.c](src/check.c) — a void method's `mi->ret` is now
`TY_UNIT`, mirroring the free-function path (the method *body* side already used `TY_UNIT`). Void
methods are now rejected in value position with the same messages as free calls ("cannot bind a
call that returns no value" for `let`, "assigned value's type does not match" for `=`), while
statement-position calls still run. Regression test `error_void_method_value.em`. 184 green.

### OFI-008 — Duplicate top-level names were not diagnosed — CLOSED
*Opened 2026-06-10; closed 2026-06-11.*

Two top-level declarations sharing a name (two `fn foo`, two `struct S`, a struct and enum both
`Point`) were accepted; resolution returned the first match, so the later one was unreachable dead
code and references silently bound to the first. **Resolution:** `type_name_taken` rejects a
second struct/enum of the same name within a module (pass 1a), and `collect_signature` rejects a
second free function of the same name within a module. Both are **per-module** — different modules
may still reuse a name (types/functions are module-scoped). Tests: `error_duplicate_fn.em`,
`error_duplicate_type.em`. (Duplicate *method* names on one struct remain undiagnosed — a smaller,
separate case.)

### OFI-012 — An expression could not span multiple lines — CLOSED
*Opened & closed 2026-06-11.*

A newline always terminated a statement, so a binary expression or argument list split across
lines failed. **Resolution:** the lexer now tracks unclosed `(`/`[` depth and suppresses the
statement-terminating newline while inside them, so a grouped expression, a call's arguments, or
an array literal may span lines (braces are *not* counted — they delimit blocks). A line that ends
with a binary operator already continued (via `should_terminate`), so both Go-style trailing
operators and Python-style bracket continuation now work. Test: `multiline_expr.em`.

### OFI-011 — A string-interpolation hole could not contain a string literal — CLOSED
*Opened & closed 2026-06-11.*

The lexer scanned a `"…"` literal to the next `"`, and the parser found a hole's closing `}` by
counting braces — neither re-entered string mode inside a `{ … }` hole. So a string literal in a
hole (`"{a.split(",")}"`) ended the outer string at the inner `"`, and a `}` inside a nested
string ended the hole early. **Resolution:** both `scan_string` (lexer) and `build_string_parts`
(parser) now track interpolation-brace depth and skip a nested string literal whole (honouring its
escapes), so the inner quote/brace is part of the hole. Arbitrary nesting works (the parser
re-lexes each hole, recursing). Test: `interpolation_nested_string.em`.

### OFI-010 — Move analysis ignored branch divergence (over-conservative after an early return) — CLOSED
*Opened 2026-06-10; closed 2026-06-11.*

The move checker OR-merged a binding's moved-state across both arms of an `if`, so a value moved
on a branch that **diverges** (always `return`/`break`/`continue`) was wrongly treated as moved
afterward — rejecting `if cond { return eat(s) } use(s)` and, once arrays became mutable move
types, the natural `loop { if done { return acc } acc.append(x) }`. **Resolution:** added
`stmt_diverges`/`block_diverges` (sound — they report divergence only when certain: a terminator,
a block ending in one, or an `if`/`else` whose arms both diverge; loops/matches conservatively
fall through), and both `STMT_IF` and `STMT_MATCH` now fold a branch/arm's moves into the join
only if it reaches the join. A genuine use-after-move on a *non-diverging* path is still caught.
Tests: `move_diverging_branch.em`, and `array_growth.em` now uses the direct early-return form.

### OFI-001 — How does `channel(N)` learn its element type? — CLOSED
*Opened & closed 2026-06-10 (resolved in the concurrency channels slice).*

`channel(200)` gives only the buffer size; the element type comes from the binding. **Resolution:**
`channel` is a built-in whose result type is taken from the **expected type** — the same
outside-in inference used for `None`/`Some` and empty arrays. `let jobs: Channel<[string]> =
channel(200)` flows `Channel<[string]>` in as the expected type, and `channel(N)` returns it; with
no annotation to infer from, it's a clear error ("annotate it…"). No turbofish needed. `Channel<T>`
is a built-in generic type (its own `CHANNEL_BASE` SemType band with element interning, mirroring
arrays); it is a *shareable* (non-move) handle so one channel can go to several tasks.

### OFI-004 — Interface-method dispatch through generic bounds (the hard one) — CLOSED
*Opened 2026-06-10 (flagged before the structs slice); closed 2026-06-10 (bounds slice).*

The genuinely hard problem: calling a bound method — `a.compare(b)` where `a: T` — when the
concrete type is unknown. **Resolution:** built the **erased dictionary-passing** path decided in
the design notes. A bounded generic function (`fn max<T: Ord>(…)`) receives a **witness** — the
concrete type's method fn-indices for the bound interface, as a small object — as a **hidden
leading argument** (local 0; real parameters shift up). `a.compare(b)` reads the method's
fn-index out of the witness and calls it via a new **`OP_CALL_INDIRECT`** (call by a runtime
fn-index); concrete calls keep the static `OP_CALL`. At the call site the checker infers `T`,
verifies it `implements` the bound (a lookup against the recorded conformance), and builds the
witness; an unbounded `T` stays opaque (no methods). Verified by `tests/run/bounded_generic.em`
and the rejection cases (non-implementing type argument, method on unbounded `T`).

Why it was tractable: the *value representation* (the echo-prone decision) was already correct —
uniform tagged `Value` means no value-witness tables (size/copy/drop), so only *method* dispatch
remained, and it was additive (one opcode + a witness object + checker annotations). Nominal
conformance made "does `T` satisfy `Ord`?" a lookup, not a coherence solve.

**Deferred as future enhancements (not the hard problem):** more than one bounded type parameter
per callable; bounds on generic *structs/enums* and *methods*; threading a witness through a
*nested* generic call (a bounded fn calling another with its abstract `T`); primitives
implementing interfaces (so `max(1, 2)` could work); and **monomorphization** as a later
release-only optimization (the erased path is the default and is correct everywhere).

**Follow-on (2026-06-15): the *value-type* side now ships too — DYNAMIC DISPATCH.** OFI-004 built
the static/bound side; using an interface *as a value type* (`let s: Shape`, `[Shape]`, params,
returns, fields) was the remaining half. Built by reusing this machinery: an interface value is a
boxed `{receiver, vtable}` pair where the **vtable is the same witness record** built here, and a
method call lowers to the same indirect dispatch (a new `OP_CALL_DYN` reads the fn-index from the
value's vtable, vs `OP_CALL_INDIRECT` reading it from local 0). New: `IFACE_BASE` SemType band,
`OBJ_INTERFACE` (owns its receiver, dropped at scope exit), implicit struct→interface upcast at the
widening sites, and an **object-safety** rule (an interface is a value type only if no method uses
`Self` beyond the receiver — non-object-safe ones stay bound-only). MANIFESTO §5b + docs/language.md
updated; `tests/run/dynamic_dispatch.em` (=>1104) + `examples/13_interfaces.em`. See the
docs/architecture.md decision for the representation.

### OFI-006 — Type-parameter substitution was not recursive (generics soundness hole) — CLOSED
*Opened & closed 2026-06-10 (found and fixed in the post-`?` code review).*

`subst` substituted a bare type parameter (`T` → `int`) but **did not recurse into nested
generic instantiations**: a field/variant typed `Inner<T>` inside `Outer<T>` kept its inner
parameter, so `Inner<T>` stayed `Inner<PARAM0>` instead of becoming `Inner<int>` under
`Outer<int>`. Effect: a valid `Outer<int> { i: Inner<int> { … } }` was **rejected** ("field value
type does not match"), and reading `o.i.v` typed as a *type parameter* leaking into concrete
checking — a soundness hole, reachable with a 5-line program. **Resolution:** made `subst`
recursive — when the type is a generic instance, it substitutes each argument and re-interns the
result (`src/check.c`); all five call sites now thread the `Checker`. Verified: nested generic
structs and `Option<Box<int>>` now run, mismatches are still caught, and two regression tests
(`generic_nested_struct`, `generic_nested_enum`) were added. Caught by the recall-biased review,
exactly the kind of latent type-system flaw worth finding before bounds/ownership build on it.

### OFI-005 — Integer overflow UB / undecided overflow semantics — CLOSED
*Opened & closed 2026-06-10 (resolved in the numeric slice).*

The VM did `a + b` / `a * b` / `-a` on `int64_t` directly — signed overflow is UB, against
CLAUDE.md's no-UB rule, and Ember had not decided overflow behaviour. **Resolution:** decided
**trap-on-overflow** (MANIFESTO §5 "Numeric types") and implemented it with clang's
`__builtin_{add,sub,mul}_overflow` (and explicit `INT64_MIN` guards on `/`, `%`, and unary `-`),
so overflow now aborts with a clear runtime error and there is no UB. Verified by a test that
overflows and traps with exit 65. A wrap-in-release mode / explicit wrapping operators remain a
possible future addition, but trapping is the floor. (That future addition is now tracked as its
own item — **OFI-041** — with hashes/PRNGs as the concrete motivation.)

### OFI-003 — Makefile lacked header-dependency tracking (stale objects) — CLOSED
*Opened & closed 2026-06-10 (found while adding local-variable opcodes).*

Adding opcodes to `opcode.h` rebuilt `codegen.o`/`vm.o` but **not** `opcode.o`, because the
Makefile had no header dependencies. The stale `opcode.o` kept the old opcode→name/operand
tables, so the disassembler desynced and printed garbage (`SUB`, `???`) even though execution
was correct. **Resolution:** added `-MMD -MP` to `CFLAGS` and `-include $(DEPS)` to the
Makefile, so each object depends on the headers it includes; verified that touching
`opcode.h` now recompiles `opcode.o`. Caught by the disassembly inspection during the locals
slice — exactly the kind of silent drift the golden tests exist to surface.
