---
title: std/http — Design of Record
nav_order: 8
description: The binding design of record for Ember's std/http — the blocking and streaming HTTPS API and its libcurl-backed transport model.
---

# Ember `std/http` — Design of Record

*Decided 2026-06-19. This is a binding design: the API and the transport model below are the plan; the
modules are built against it. Decisions trace to [MANIFESTO.md](https://github.com/kmcnally5/ember-lang/blob/main/MANIFESTO.md). Supersedes the
ad-hoc `extern http_post` the desktop apps use today.*

## Thesis

**HTTP is structured-concurrency I/O, not async/await.** A request is a blocking-looking call run on a
fiber; a streaming body is a `Channel<…>` that a worker fiber feeds. No futures, no `.await`, no function
coloring, no `Send + Sync` virality — the things the manifesto rejects in Rust async (§3.2). We take Go's
"blocking call on a cheap thread" ergonomics and fix Go's footguns (leaked undrained bodies, one coarse
deadline) *structurally*, because the **nursery scope owns the request** and tears it down on exit (§5,
concurrency primitive).

## The transport model — PULL via an opaque handle (not a push native)

The research draft proposed a runtime-aware native whose libcurl write-callback calls `em_channel_send`.
**Rejected for the MVP** in favour of a simpler, more on-thesis model:

> Streaming is `curl_multi` behind a `Ptr` handle, driven by **pull**. The transport is three plain
> `extern "c"` leaves; **the Ember worker fiber owns the channel and does the `send`s itself.**

```
extern "c" {
    fn http_open(url: string, headers: string, body: string) -> Ptr   // POST, returns a stream handle
    fn http_next(h: Ptr) -> string                                    // next body chunk; "" at end
    fn http_status(h: Ptr) -> int                                     // HTTP status (0 until known)
    fn http_close(h: Ptr)                                             // free the handle
}
```

`http_next` pumps `curl_multi_perform`/`curl_multi_poll` until a chunk arrives or the transfer ends, then
returns it. Chunks arrive incrementally as the network delivers them — true streaming. **Why this beats
the push native:** it needs ZERO runtime/checker changes (it's the existing `fopen`/`fread`/`fclose`
`Ptr` leaf-FFI pattern, §5h, OFI-049 made `Ptr` move-only/safe); it keeps concurrency 100% Ember
(fibers + channels), which is *more* on-thesis; and the blocking lives in `http_next` on a worker fiber,
exactly like `http_post` blocks today. The push-native is only worth it for the later curl_multi-reactor
phase (one thread, thousands of connections) — see Phase 1.

## The Ember API surface (`std/http`)

```rust
enum Method { Get, Post, Put, Delete, Patch, Head, Options }

enum HttpError { Dns(string), Connect(string), Tls(string), Timeout, Cancelled, Protocol(string) }

struct Request { /* method, url, headers, body, timeouts */ }
fn get(url: string) -> Request
fn post(url: string) -> Request
fn Request.header(mut self, name: string, value: string) -> Request
fn Request.body(mut self, s: string) -> Request

struct Response { /* status, headers, body */ }
fn Response.status(self)  -> int            // a FIELD, not an error (decision D2)
fn Response.text(self)    -> string         // full body (90% path)
fn Response.header(self, name: string) -> Option<string>

// blocking full-body (the simple path) — runs on the calling fiber:
fn send(req: Request) -> Result<Response, HttpError>

// streaming: the worker pumps http_next into `out`, closing it at end-of-stream. The caller spawns it
// in a nursery and drains `out`; nursery-exit cancels the in-flight request (structural cancellation).
fn pump(req: Request, out: Channel<string>)
```

SSE is a thin layer that never lives in `std/http`:

```rust
// std/sse — Channel<string> (raw bytes) -> Event stream. Pull-based, no callbacks (§5g).
struct Event { name: string, data: string }
fn feed(decoder: mut Decoder, bytes: string) -> [Event]
```

JSON is its own module (`std/json`, decision D3) so `std/http` stays protocol-agnostic and the fragile
`split("\"text\":\"")` in the apps dies.


## Status — realized 2026-06-20

The first shipped `std/http.em` is a **thin wrapper over the C externs**, not yet the `Request`/`Response`
builder above. It exposes exactly the surface the desktop apps already used inline, lifted into one module:

```ember
fn post(url: string, headers: string, body: string) -> string      // blocking POST, whole body at once
fn get(url: string, headers: string) -> string                     // blocking GET (short timeouts), whole body
fn open(url: string, headers: string, body: string) -> Ptr         // streaming POST → handle
fn next(h: Ptr) -> string                                          // next chunk ("" at end of stream)
fn status(h: Ptr) -> i64
fn close(move h: Ptr) -> i64                                       // consumes the linear handle
```

`get` (added 2026-06-23) is the read counterpart to `post`: a blocking GET with a short connect/total
timeout (4 s / 20 s) so a discovery probe against a down or slow host fails fast instead of hanging the
caller. It was driven by the Claude app's local‑model support — listing installed Ollama models is a
`GET /api/tags`, and the streaming `open`/`post` are both POST‑only. A transfer failure comes back as the
same `{"_curl_error":"…"}` sentinel string `post` uses, so the caller always gets an inspectable string.

`chat.em` (blocking `http.post`) and the new reusable `anthropic` client (streaming `http.open`/`next`/
`close`, fed to `std/sse`) both import it; the inline `extern http_post`/`http_open` blocks are gone —
**Phase 0's "delete `extern http_post` from both apps" is done.** The richer builder API (`Request`/
`Response`/`Method`/`HttpError`, `send`/`pump`) remains the planned evolution, and must design around one
real constraint: `Ptr` is a linear type that **cannot be a struct field** (OFI-049's erasure-proof
type-formation ban), so a `Response` object cannot simply *hold* an open stream handle — the streaming
surface stays handle-passing (`open`/`next`/`close`) until that is resolved. Lifting the spawnable
streaming worker into a library module also surfaced and closed **OFI-091** (qualified-callee `spawn`).

### Claude's streaming loop (the dogfood target)

```rust
nursery {
    spawn http.pump(req, raw)                 // raw: Channel<string>
    var dec = sse.decoder()
    loop {
        match recv(raw) {
            None        => break               // stream closed
            Some(bytes) => {
                for ev in sse.feed(dec, bytes) {
                    if ev.name == "content_block_delta" {
                        send(tokens, json.text_delta(ev.data))   // typewriter → UI channel
                    }
                }
            }
        }
    }
}
```

N parallel requests = N `spawn`s in a nursery; the nursery joins (and cancels laggards) on exit.

## Decisions (D1–D6, decided 2026-06-19)

- **D1 — streaming body is `Channel<string>` (bytes).** A fiber on `recv()` already *is* a blocking
  reader, with backpressure + scope-cancellation free. No `Reader` type. (§3.2, §5)
- **D2 — HTTP status is a `Response` field, not an error.** `send` fails only on transport. Fixes
  today's real bug (a 401 body becoming the "reply"). (§2.4, errors-as-values)
- **D3 — three modules, one milestone: `std/http` + `std/sse` + `std/json`.** Composable, small surface.
- **D4 — capabilities (`Net`/`Fs`/`Clock`/…) are adopted as the NEXT language milestone, not here.**
  Capability-passing (`fn f(net: Net)` — code provably can't touch the network without the token) is the
  strongest expression of the LLM-first principle (§5b): a reader knows a function's authority from its
  signature. It is *not yet in the manifesto* (the research over-cited a "§5i"); it is a new decision to
  be specced and added manifesto-wide (it touches `main`, the runtime root-grant, and all effectful
  stdlib). http ships without it now and gains `Net` then — breaking is fine, we are pre-1.0.
- **D5 — libcurl through Phase 1.** TLS/h2/redirects/gzip for free; it is the one blessed opt-in dep
  (raylib precedent, §3.5). Pure-Ember sockets+TLS is a separate future project; the API makes the swap
  non-breaking.
- **D6 — fibers: the "M:N green threads" gap is resolved.** The M:N scheduler is built (OFI-071,
  gated behind `EMBER_MN`); the default build keeps the 1:1 OS-thread-per-`spawn` model that this
  design's Phase 0 assumes (one OS thread per in-flight request).

## Implementation phases

- **Phase 0 — MVP (this milestone).** The three `curl_multi` `Ptr` externs above + `std/http` (`get`/
  `post`/`send`/`pump`/`Response`) + `std/sse` + `std/json` (real parse). Convert `flare_chat.em` to a
  streaming typewriter and delete `extern http_post`/`build_request`/`extract_text` from both apps.
  *Tradeoff:* one OS thread per in-flight request (fine for a chat app, 1–4 concurrent). Cancellation is
  real but coarse (aborts at the next `http_next` pump, via `CURLOPT_XFERINFOFUNCTION`).
- **Phase 1 — world-class.** A single `curl_multi` reactor on the fiber scheduler: thousands of
  connections on ~1 thread, per-host keep-alive/pooling (kills per-turn TLS handshakes), redirects,
  retry/backoff honouring `Retry-After`. *Same `std/http` API* — only the transport guts change. Here a
  runtime-aware native (the rejected push model) becomes the right tool, because the reactor's callbacks
  no longer run on the caller's thread.

## Manifesto trace

| Decision | Principle |
|---|---|
| Blocking `send`/`pump`, no async/await/futures | §3.2 (no function coloring) |
| `nursery { spawn }` + `Channel<T>`, one runtime, scope-cancellation | §5 (concurrency primitive) |
| `Result<Response, HttpError>` + `?`; status is a field; `Option` headers | errors-as-values, no null |
| Streaming chunks are owned `string`s, never escaping borrowed slices | §5f, OFI-009 |
| Pull channel reads, never registered callbacks | §5g (no hidden control flow) |
| libcurl opt-in, off the default `make`/`make test` path; never named in Ember | §3.5, §5g (raylib precedent) |
| Transport is `Ptr`-handle leaf FFI, copy-out, no C-owned pointer escapes | §5h, OFI-043/049 |
| One canonical client shape, least-surprise names | §5b |
| (later) `Net` capability makes network authority legible | §5b (LLM-first) |
