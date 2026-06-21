# Closing the gap with the real Anthropic Claude app

*Roadmap of record, 2026-06-19. Benchmark: the actual claude.ai web + desktop app — not our old gui.em.*

# Ember Flare Claude App — Roadmap to Close the Gap

## 1. Honest assessment

`flare_chat.em` already nails the single hardest thing — real token-by-token streaming over libcurl, driven by first-class channels/nursery on a true OS thread, rendered live as Markdown — which is the load-bearing core of a chat app and is genuinely production-shaped. What it is *not* yet is a product: it's a single ephemeral conversation with a decorative sidebar, no persistence, no model/system controls, no stop button, no copy affordance, stripped (not styled) inline markdown, and zero multimodal. The gap is almost entirely **breadth of UI surface + two missing primitives** (a real JSON parser and a binary/image data path), not architecture. Tier 1 is days of pure-Ember wiring on primitives that already exist; the app *feels* like a toy today mostly because of small missing buttons, not deep limitations.

## 2. Tiered roadmap

### TIER 1 — "Feels like Claude" (FEASIBLE-NOW, pure-Ember wiring)

| Feature | What it is | Needs | Effort | Value |
|---|---|---|---|---|
| Stop / cancel generation | Esc / button halts an in-flight stream | Channel signal (or shared `mut` flag) → worker breaks `http_next` loop, calls `http_close`. No C. | S | High |
| Copy message + copy code block | Per-turn and per-fence copy button | `clipboard_set` (already wired); add Flare button. gui.em already has per-block copy. | S | High |
| Model selector | Opus/Sonnet/Haiku picker | `model` is already a request field; Flare buttons/dropdown. gui.em already does this. | S | High |
| In-memory conversation history | Multiple named chats in the sidebar (live "Recents") | Array of transcripts + sidebar list; switch swaps `msgs`/`mine`. No C. | S | High |
| Zoom + keyboard shortcuts | Send/newline/stop/new-chat/copy/font-scale | `key_pressed`/`key_down` exist; `set_font` size scaling exists. Wire the Claude shortcut set. | S | High |
| Inline bold / italic / code styling | Render `**`/`*`/`` ` `` instead of stripping | (1) inline span parser extending `std/markdown.em`; (2) Bold/Italic TTF in a `load_font` slot, `set_font` per run; mixed-weight line layout. No C. | M | High |
| Markdown tables | `\|`-delimited grids | New `Block::Table` variant + column layout via `measure_text` + rect/clip. No C. | M | Med |

### TIER 2 — "Iconic Claude" (meaty, defining)

| Feature | What it is | Needs | Effort | Value |
|---|---|---|---|---|
| On-disk persistence | Conversations survive restart; real Recents list | `read_file`/`write_file` (exist) + **`std/json`** for robust serialize/load. M if multi-conversation management. | S–M | High |
| Extended-thinking display | Collapsible reasoning panel, per-message toggle | SSE decoder handles `thinking`/`signature_delta` (today only pulls `text`); request `thinking:{...}` flag; **`std/json`** to demux interleaved blocks; collapsible Flare panel. | M | High |
| Image attachments + VISION | Attach/paste image, model sees it, thumbnail in UI | **NEW: texture externs** (`LoadTexture`/`DrawTexture`/`LoadImageFromMemory` — linked, not wired) + **NEW: base64** (~40 LoC Ember) + binary file read (`fread` loop or `file_size` extern). API side = base64 `image` block. | M | High |
| Artifacts side-panel (code/text) | Side panel rendering highlighted code / Markdown docs | Pure layout: scroll/clip/layers + `std/highlight` (all exist) + extraction logic + preview/code toggle. *Rendered* HTML/SVG is out of scope (NEEDS-NEW-PRIMITIVE: SVG-subset renderer). | L | High |

### TIER 3 — "Platform"

| Feature | What it is | Needs | Effort | Value |
|---|---|---|---|---|
| Web search (server tool) | Cited real-time results | `tools:[web_search_20250305]` request field; Anthropic runs it; render `tool_use`/citation blocks. **`std/json`** to parse. | M | High |
| Client tool_use | Define tools, run them, return `tool_result` | **`std/json`** parser/serializer (the blocker) + follow-up POST turns. Transport already supports it. | M–L | Med |
| MCP connectors (remote) | `mcp_servers` request param, Anthropic-proxied | Request fields + rendering + **`std/json`**. (Local stdio MCP = NEEDS subprocess-spawn extern.) | M | Med |
| Projects (knowledge base) | Per-project files + custom instructions carried into each chat | On-disk persistence (Tier 2) + system-prompt field + file concat into context. **`std/json`**. | M | Med |
| Code execution | Server-side `code_execution` sandbox | Request field + render result blocks. **`std/json`**. | M | Med |
| File/PDF upload | Document attachments | **Route (a):** base64 `document` block — collapses into the vision data path (preferred). **Route (b):** Files API needs **NEW: `http_post_multipart`** (curl `curl_mime_*`). | M | Med |

## 3. New primitives that unlock the most

| Primitive | Unlocks | In codebase today? |
|---|---|---|
| **`std/json` parser/serializer** (pure Ember, no C) | Persistence, extended-thinking, ALL of Tier 3 (tools/MCP/projects/code-exec). Single highest-leverage item — current `extract_text` is a `split("\"text\":\"")` hack flagged TODO in-code. | **No.** Only the app's ad-hoc helpers + a compiler-internal `src/json.c`. Build it. |
| **base64 encoder** (~40 LoC pure Ember) | Vision, image thumbnails, PDF/document blocks. | **No.** Not in std, not in C. Trivial to add. |
| **Texture/image externs** (`LoadTexture`/`DrawTexture`/`LoadImageFromMemory`) | Displaying images, screenshot paste, avatars — the *display* half of vision. | **Linked but not wired.** Full raylib is in the binary (`LoadTextureFromImage` used internally `graphics.c:294`); needs a handful of `ember_gfx_*` wrappers in `graphics.c`/`graphics.h`. S. |
| **Binary file read** (`file_size` extern or `fread` loop) | Reading image/PDF bytes safely (`read_file` returns a non-binary-safe string). | **Partial.** `fread`/`fopen` FFI exists; just need length. S. |
| **Drag-drop externs** (`IsFileDropped`/`GetDroppedFiles`) | Drop-to-attach files. | **Linked but not wired.** S. Optional polish. |
| **`http_post_multipart`** (curl `curl_mime_*`) | Files API only (`/v1/files`). Avoidable via base64 document blocks. | **No.** M. Defer — base64 route makes it optional. |
| **Subprocess spawn** | Local stdio MCP servers only. | **No.** M. Defer — remote MCP needs none of it. |

**Takeaway:** `std/json` + (base64 + texture externs + binary read) are the two clusters that, once landed, unblock essentially the entire Tier 2/3 list.

## 4. Recommended build order (next 8 steps, each shippable + verifiable)

1. **Stop generation** — add a stop channel/`mut` flag; Esc and a composer-side button break the worker's `http_next` loop and `http_close`. *Verify:* start a long reply, hit Esc, stream halts, app stays responsive, can send again. (S, no C)

2. **Copy buttons + keyboard shortcuts** — per-message and per-code-block copy via `clipboard_set`; wire the Claude shortcut set (Enter/Shift-Enter/Esc/new-chat/copy/font zoom). *Verify:* copy round-trips via `clipboard_get`; each shortcut fires; tape-record a frame to confirm. (S)

3. **Model selector + in-memory multi-conversation** — Flare model buttons writing the request `model`; convert the sidebar to a live list of in-memory transcripts with New/switch/delete. *Verify:* switch model mid-session and confirm in request; create 3 chats, switch between them, transcripts stay distinct. (S)
   - **DONE 2026-06-19.** *Model selector:* a sidebar `Model · …` button cycles Opus 4.1 → Sonnet 4.5 → Haiku 4.5 and feeds `build_request`; `ANTHROPIC_MODEL` pins it ("Model · (env)"). *Multi-conversation:* a `Conv` store + live "Recents" list (active chat = primary); New chat and click-to-switch, with the active transcript kept in flat working `msgs`/`mine`. This surfaced **OFI-072** — `arr[i].field.append(x)` silently no-ops (a `mut self` method whose receiver is reached through an index mutates a temporary), so switching uses the *checkout* pattern: whole-array write-back through the index (persists) + `slice(0,len)` copy-out. Locked by `tests/run/array_field_checkout.em`. *Deferred:* per-chat **delete** needs an array `remove_at(i)` (stdlib has only `remove_last`) — a small stdlib add, folded into the persistence step.

4. **`std/json` module** (`std/json.em`) — a real parser + serializer (objects/arrays/strings/numbers/bools/null, escape-correct). Replace `build_request`/`extract_text`/`json_escape` in `flare_chat.em`. *Verify:* unit test in `tests/` round-tripping nested objects + escaped strings; the live app still streams identically. This is the keystone — do it before Tier 2/3. (M)
   - **DONE 2026-06-19.** `std/json.em`: a recursive `Json` sum type + recursive-descent parser (`parse → Result<Json,string>`, `stringify`, builders `obj/arr/str/num/real/boolean/member`, accessors `get/at/as_str/as_int/as_real/as_bool/is_null/length`). **Adversarially hardened** via a verification workflow (4 agents, ~186 cases): 11 bugs found → fixed strict JSON number grammar (rejects `01`/`1.`/`1e`/`-`/`1e2e3`), non-finite rejection (`1e400`), UTF-16 surrogate-pair low-half validation, unescaped-control-char rejection, and depth caps on both parse (64, no stack-overflow abort) and stringify. Regression `tests/run/json.em` (+ native `Result`-using dual-run); VM==native parity. `flare_chat`'s `build_request`/`extract_text` now build/parse via std/json (hand-rolled `json_escape`/`hex_*`/`join_commas` deleted) — request JSON round-trips with correct quote/newline/unicode escaping, `delta.text`/`error.message` extracted by path. Surfaced **OFI-073** (global enum-variant-uniqueness: json's `Str` collided with `highlight.Kind.Str` → renamed to `Text`; `Ok/Err` collided with built-in `Result` → used it).

5. **On-disk persistence** — serialize each conversation to JSON via `std/json` + `write_file`; load the Recents list on startup via `read_file`. *Verify:* send messages, quit, relaunch, conversations reappear; add a `tests/` round-trip test. (S–M)

6. **Inline bold/italic/code styling** — extend `std/markdown.em` with an inline span parser; load Bold/Italic TTF slots; render mixed-weight runs in `f.markdown`. *Verify:* `.em` sample rendering `**bold**`, `*italic*`, `` `code` `` shows correct weights (not stripped); screenshot. (M)

7. **base64 + texture externs + binary read** — add `std/base64.em`; wire `LoadTexture`/`DrawTexture`/`LoadImageFromMemory` (+ `file_size`) in `graphics.c`/`graphics.h`. *Verify:* encode a known buffer matches a reference; load a PNG from disk and draw it in-window. (M; the only C work in this list)

8. **Image attachments + VISION** — attach/paste an image → binary read → base64 → `image` content block; render a thumbnail via the new texture extern. *Verify:* attach a chart screenshot, ask Claude to describe it, get a correct vision response; thumbnail shows in the transcript. (M)

After step 8 the app feels like Claude and has the multimodal + data-path foundation; **extended-thinking display** (needs only `std/json`, already landed) and the **artifacts code/text side-panel** are the natural next two, then Tier 3 platform features ride almost entirely on `std/json` + follow-up POSTs.

**Files to touch:** `public/claude-desktop/flare_chat.em` (every step), new `std/json.em` / `std/base64.em`, `std/markdown.em` (step 6), `src/graphics.c` + `include/graphics.h` (step 7), plus `tests/` for steps 4/5/7.
