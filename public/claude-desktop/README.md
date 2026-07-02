# Claude Desktop (Ember)

A Claude Desktop look‑alike written in **Ember** — the acid test for the language: a real,
interactive, network‑backed desktop application driven by the Anthropic Messages API.

This is the flagship **example application** for Ember — the largest piece of dogfooding in the
repo — with its own README here. It is **not** part of the language core or standard library; it
is a real, shippable app *written in* Ember, and it exists to harden the language under the load of
a genuine networked, interactive program.

## What it is

- **Phase 1 — the bridge (done).** A CLI (`chat.em`) that talks to Claude over HTTPS: it reads
  `ANTHROPIC_API_KEY` from the environment, builds a Messages‑API request, POSTs it, and prints
  Claude's reply. This proves Ember ↔ Anthropic end‑to‑end.
- **Phase 2 — the GUI (done).** A desktop window (`gui.em`) styled like Claude Desktop for macOS:
  a warm sidebar (Claude mark, "+ New chat"), a centred conversation column with right‑aligned user
  bubbles and left‑aligned "Claude" replies, word‑wrapping + scroll, a full text editor in the input
  bar (caret, arrows, repeat, blink), and a coral send button. Built on Ember's raylib graphics
  backend; the full multi‑turn history is sent to the API each turn.
- **Phase 3 — Flare rewrite (done, current primary app).** `flare_chat.em` rebuilds the desktop
  app on `std/flare` (Ember's React-ergonomics UI layer) with `std/sse` + `std/json` for true
  token-by-token streaming. Features: switchable conversation list, scrollable markdown transcript
  (`std/markdown` + `std/highlight`), a `text_area` composer (Shift+Enter newline, Enter send),
  a settings modal with `segmented` controls for model / max-tokens / theme / zoom, and full
  session persistence. Build with `make net-graphics` and run via `./run-flare.sh`.
- **Phase 4 — dockable workspace (done).** The whole body is now a **dock** built on `std/flare`'s
  `DockTree`: three panels — **Conversations** | **Chat** | **Inspector** — that you **resize by
  dragging the dividers** and **close with each panel's ✕**. *Chat* is the pinned anchor (no ✕); the
  side panels are closeable and re-dock from the Chat toolbar (`☰ Chats` / `ⓘ Inspector`), and the
  Inspector's *Reset layout* restores the default. The **Inspector** shows the live context at a
  glance — model, max tokens, message/tool-call counts, the system prompt, and the available tools.
  Panels FLIP-animate on dock/close and snap during a resize. This is the dogfood that drove
  `dock_begin` / `dock_panel` / `dock_pin` into the language (see `docs/flare.md` → *Docking*).
- **Phase 5 — local models via Ollama (done).** The app is no longer Claude‑only: a **Provider**
  toggle in Settings switches between **Claude (API)** and **Ollama (local)**. With Ollama selected,
  the app discovers the chat models installed on your machine (`GET /api/tags`) and lists them to
  pick from; messages then stream from the local model over Ollama's OpenAI‑compatible
  `/v1/chat/completions` endpoint — **no API key, nothing leaves the machine**. This is the one thing
  Anthropic's own Claude Desktop can't ship: a provider‑agnostic client that also runs fully local.
  See *Local models (Ollama)* below.

## Features

Everything here is wired to real behaviour — it's meant to be a *usable* app, not a mockup.

- **Settings panel** (gear at the bottom of the sidebar, or ⌘,) — all options take effect:
  - **Appearance** — Dark / Light theme (re‑themes the whole app).
  - **Provider** — Claude (API) / Ollama (local). Choosing Ollama discovers and lists the chat
    models installed on your machine; pick one (or **Refresh models**). See *Local models (Ollama)*.
  - **Model** — Opus 4.8 / Sonnet 4.6 / Haiku 4.5 (the Anthropic `model`; replaced by the discovered
    local‑model list when the provider is Ollama).
  - **Max tokens** — 1K / 2K / 4K / 8K (changes the request).
  - **Zoom** — 60–220% (scales the conversation text + column).
  - **System prompt** — an editable field, sent to the API as `system`.
- **Zoom** — ⌘+ / ⌘− / ⌘‑scroll, or the settings buttons.
- **Resizable window** — the layout tracks the live window size.
- **Copy code** — a Copy button on every code block (→ system clipboard).
- **Paste** — ⌘V into the input or the system‑prompt field.
- **Keyboard shortcuts** — ⌘N new chat · ⌘, settings · Esc close · ⌘+/⌘− zoom · ⌘V paste · Enter send.
- **Prompt starters** — clickable suggestions on the empty screen.
- **Scroll‑to‑bottom** button when you've scrolled up; a live character counter on the input.

**Desktop chrome (a Flare primitive campaign — each feature drove a reusable `std/flare` widget, see
[docs/flare.md](../../docs/flare.md)):**

- **Menu bar** — a File / View / Help strip across the top (dropdowns with keyboard accelerators + a
  nested "Export" submenu). `f.menubar_begin` / `f.menu` / `f.menu_item_accel` / `f.submenu`.
- **Command palette** — **⌘K** opens a fuzzy launcher for every action (new chat, settings, theme,
  zoom, re-dock, export, quit). `f.command_palette`.
- **Settings controls** — the Appearance toggle is a **checkbox**, the Model picker a **dropdown**, and
  the text size a **slider** (was a segmented + buttons). `f.checkbox` / `f.dropdown` / `f.slider`.
- **Slash commands** — typing **`/`** in the composer pops a typeahead (`/new`, `/settings`, `/theme`,
  `/copy`, `/quit`); Enter/Tab/click runs it. `f.typeahead`.
- **Conversation tabs** — the conversations you open this session sit as **closeable, reorderable tabs**
  above the chat (VS Code editor-tabs model; the sidebar stays the full list). `f.tabs`.
- **Right-click + tooltips** — **right-click** a conversation for its context menu; hover a toolbar
  button for a **tooltip**. `f.right_clicked` / `f.tooltip`.
- **Attachments** — **drag files** onto the window to stage them as chips; they're folded into the next
  message. `dropped_files()`.

These rest on small, reusable graphics natives added to the language: `clipboard_set`/`clipboard_get`,
`screen_width`/`screen_height` (+ a resizable window), `load_font`/`set_font`, `key_repeat`, and — for the
desktop-chrome campaign — **`mouse_right_down()`** (right-click context menus) and **`dropped_files()`**
(the newline-joined paths dragged onto the window this frame).

## Fonts

The app loads three faces at runtime via the `load_font(path) -> id` / `set_font(id)` graphics
natives (font 0 is the embedded Inter, always present as a fallback):

- **Inter** (embedded) — body text and the input field.
- **New York** (`/System/Library/Fonts/NewYork.ttf`) — Apple's editorial serif, used for the
  "Claude" wordmark and the "How can I help you today?" greeting.
- **SF Mono** (`/System/Library/Fonts/SFNSMono.ttf`) — code blocks.

Loading at runtime (rather than embedding) keeps the repo lean and is the correct way to use
Apple's system fonts (they may be used by apps on the platform but not redistributed/embedded). Each
`load_font` returns `-1` if the file isn't there, and the app falls back to the body font — so it
still runs on a non‑mac. **To try other faces, just change the path string** in `gui.em` — e.g.
`/System/Library/Fonts/Supplemental/Georgia.ttf`, `.../Charter.ttc`, `.../Baskerville.ttc`, or a
downloaded OFL font like Fraunces / JetBrains Mono.

## How Ember talks to the Anthropic API

Ember has no networking of its own, so the app **executes a C library** through the FFI — the same
way you'd call libc, but for libcurl:

```ember
extern "c" {
    fn http_post(url: string, headers: string, body: string) -> string
}
```

Two pieces of language work made this possible (both landed in the core compiler):

1. **FFI string return** (`ret_is_string`, closes OFI‑043's read direction). A C wrapper returns a
   `malloc`'d `char*`; the FFI marshalling copies it into an owned Ember `string` and frees the C
   buffer — "copy‑on‑return". Before this, the FFI could only *send* borrowed pointers to C.
2. **A libcurl `http_post` wrapper** (`src/cextern.c`, guarded by `#if EMBER_NET`). It does the
   HTTPS POST with a write‑callback into a growing buffer and hands the response back as the string.
   It is **opt‑in**, exactly like the raylib graphics backend — the default `make` / `make test`
   stay dependency‑free. The `headers` argument is one string of `\n`‑separated header lines.

This is "Tadpole for Ember": a thin, typed bridge to a battle‑tested C HTTP stack, with all of the
request building and response parsing written in pure Ember.

## Local models (Ollama)

The same app talks to **local models** via [Ollama](https://ollama.com) — no API key, no cloud. In
**Settings → Provider** choose **Ollama (local)**; the app lists the chat‑capable models installed on
your machine and streams replies from the one you pick.

```sh
# one-time: install Ollama and pull a model
ollama serve &            # start the local daemon (http://localhost:11434)
ollama pull llama3.2      # or any chat model — mistral-nemo, qwen2.5, phi4, …

# then launch the GUI build and switch Provider → Ollama in Settings
make net-graphics
build/emberc-net-gfx --emit=run public/claude-desktop/flare_chat.em
```

**How it works.** Model discovery is a `GET /api/tags` (the new `std/http.get`), filtered to
completion‑capable models (embedding‑only models are hidden). Chat uses Ollama's
**OpenAI‑compatible** `/v1/chat/completions` with `stream: true`, so its Server‑Sent Events decode
through the same `std/sse` as the Anthropic path — *one streaming code path, two providers*. The
client lives in `ollama.em` (the twin of `anthropic.em`); a second worker fiber runs it alongside the
Claude worker, and replies multiplex onto the one response channel the render loop already drains.

- **`OLLAMA_HOST`** (optional) — point at a non‑default daemon (`host:port` or a full URL). Defaults
  to `http://localhost:11434`.
- **No key needed.** Readiness for Ollama is "a model is selected", not an API key. If no model is
  found, the app tells you to run `ollama serve` and `ollama pull <model>`.
- **Tools are Claude‑only for now.** The `read_file` / `write_file` agentic tools use the Anthropic
  tool wire format; local models run as plain chat (OFI‑135 tracks OpenAI‑format tool mapping).

## Build & run

```sh
# from the repo root — build the compiler with libcurl linked
make net

# set your key and ask Claude something
export ANTHROPIC_API_KEY=sk-ant-...
build/emberc-net --emit=run public/claude-desktop/chat.em "Explain Ember in one sentence."
```

`./run.sh "your message"` does both steps. The model defaults to `claude-opus-4-8`.

### The GUI

```sh
# from the repo root — build the compiler with libcurl AND raylib linked
make net-graphics

export ANTHROPIC_API_KEY=sk-ant-...
build/emberc-net-gfx --emit=run public/claude-desktop/gui.em
```

`./run-gui.sh` does both steps. Type a message and press **Enter** *or click the coral send
button* to send; the conversation scrolls with the mouse wheel; **New chat** clears it. You can
type and click without a key set — sending then just replies with a reminder to set
`ANTHROPIC_API_KEY`.

### Debugging interactivity with the UI tape

Set `EMBER_TAPE=/path` and every frame is appended to that file as one JSON line — the input
snapshot (`mouse`, `down`) plus every draw command — `fflush`ed each frame, so `tail -f` shows the
loop live. Clicks that the app *acts on* show up as `{"event":"submit",…}` / `{"event":"new_chat",…}`
marks. This is how the "frozen window" was diagnosed: the `frame` counter was climbing and `mouse`
positions were changing the whole time, which proved the loop and OS input were fine and the app
simply wasn't wiring the clicks.

```sh
EMBER_TAPE=/tmp/gui.tape build/emberc-net-gfx --emit=run public/claude-desktop/gui.em
# in another terminal:
tail -f /tmp/gui.tape
```

The whole GUI — layout, message bubbles, word‑wrap, scroll, the text input, the JSON request/reply
handling — is pure Ember (`gui.em`, ~430 lines). Only two things are C: the HTTPS transport
(libcurl, via `http_post`) and the windowing/drawing primitives (raylib, the same backend the
`examples/*_ui.em` demos use).

## Notes & gotchas

- **JSON braces must be escaped in Ember string literals** (`\{` `\}`) because `{...}` is string
  interpolation. `chat.em` builds JSON with a small set of helpers + `from_char_code` for the
  structural characters, and a `json_escape` for the user's text.
- The whole JSON request/response handling is **pure Ember** — only the transport is C.
- The combined GUI build (Phase 2) is `make net-graphics` → `build/emberc-net-gfx`.
- **The GUI runs on the VM.** Graphics is a VM-only backend (`--emit=run`), so `gui.em` is not
  compiled by the native AST→C backend; the network CLI (`chat.em`) runs on either.
- **Input must be wired explicitly.** raylib (via `frame_end`→`EndDrawing`) polls OS input every
  frame and the live getters `mouse_x`/`mouse_y`/`mouse_down`/`char_pressed`/`key_pressed` read it —
  but a widget only reacts if the app hit-tests it. The send button and **New chat** pill are
  edge-triggered against `mouse_down` (one action per physical press, tracked with a `was_down`
  flag). A drawn-but-not-hit-tested control looks "frozen" even though the window is fully alive.
- **The API call is now ASYNCHRONOUS — the window stays live while Claude replies.** A long-lived
  `fetch_worker` fiber is `spawn`ed (once) inside a `nursery` that wraps the whole render loop; the
  loop dispatches the request body on a `Channel<string>` and polls the reply channel every frame
  with the non-blocking **`try_recv`** (the "Claude is thinking…" dot/label animate to show it). The
  blocking `http_post` runs on the worker's **own OS thread** while `window_open` + the render loop
  stay on thread 0 (macOS requires the Cocoa event loop on the main thread); closing the request
  channel at shutdown wakes the worker and the nursery joins it. This needs the **parallel runtime**,
  so `make net-graphics` now builds with `-DEMBER_PARALLEL`. Three language pieces landed to make this
  work: spawn-at-spawn-time (a spawned task runs concurrently with the nursery body), `try_recv`, and
  refcounted (leak-free) channels — see the architecture decisions. *Still synchronous in one sense:*
  the worker returns the WHOLE reply at once; true token-by-token SSE streaming (a curl write-callback
  bridged into the channel) is the next iteration. Known edge: closing the window mid-request waits
  for that request to finish before the nursery joins.
- The GUI sends the **entire conversation** each turn (the Messages API is stateless), so Claude
  has full context across the session.
- **No `temperature` in the request.** It is deprecated for the current models (Opus 4.8 returns
  `"temperature is deprecated for this model"`), so the request omits it and the model uses its
  default; the Temperature setting was removed rather than left as an inert control.
- **API errors render cleanly.** `extract_text` looks for the reply's `"text"`; if absent (an error
  envelope), it surfaces the error `"message"` prefixed with `API error:` instead of dumping the raw
  JSON blob at the user.
