// ollama.em — a client for a LOCAL Ollama server, so the Claude desktop app can talk to models
// running on your own machine (no API key, no cloud). It mirrors anthropic.em's shape but speaks
// Ollama's OpenAI-COMPATIBLE surface: GET /api/tags to discover installed models, and a streaming
// POST /v1/chat/completions whose Server-Sent Events carry `choices[0].delta.content` token by token.
//
// Why OpenAI-compatible and not Ollama's native /api/chat? The /v1 endpoint frames its stream as
// standard SSE (blank-line-delimited `data:` events), so it reuses std/sse UNCHANGED — and the very
// same code path will later light up OpenAI, OpenRouter, LM Studio, Groq and friends behind a base
// URL. Ollama's native API would have meant a second NDJSON reader for no extra reach.
//
// MVP scope (Ollama-only first pass): plain text chat, no tool use. The transcript MODEL (Turn) and
// the resp_ch control protocol (done_mark) are reused from anthropic.em so the app's one streaming
// drain loop works no matter which provider produced the reply — both workers feed the same channel.
//
// Needs the networking build (`make net` / `make net-graphics`). Import from a sibling file:
//   import "ollama" as oll
import "std/http" as http
import "std/sse" as sse
import "std/json" as json
import "std/string" as str
import "anthropic" as api      // reuse Turn (the transcript model) + done_mark (the resp_ch protocol)


// The default endpoint of a local Ollama daemon. Overridable by the app (and by $OLLAMA_HOST below).
let DEFAULT_BASE = "http://localhost:11434"


// default_base resolves the Ollama endpoint to talk to: $OLLAMA_HOST when set (a full URL is taken
// as-is, a bare "host:port" is given an http:// scheme — matching the ollama CLI's own variable),
// otherwise the local default. The app seeds its stored base from this on first run.
fn default_base() -> string {
    let h = env("OLLAMA_HOST")
    if h.len() == 0 {
        return DEFAULT_BASE
    }
    if h.len() >= 4 && str.substring(h, 0, 4) == "http" {
        return h
    }
    return "http://{h}"
}


// _is_chat reports whether a model entry from /api/tags can do chat completion. Ollama tags each
// model with `capabilities` (e.g. ["completion","tools"] for a chat model, ["embedding"] for an
// embedder); we keep only completion-capable ones. An older daemon that omits the field is assumed
// usable rather than hidden, so the picker never comes up empty on a server that predates the flag.
fn _is_chat(m: json.Json) -> bool {
    let caps = json.get(m, "capabilities")
    let n = json.length(caps)
    if n == 0 {
        return true
    }
    var i = 0
    loop {
        if i == n {
            break
        }
        if json.as_str(json.at(caps, i)) == "completion" {
            return true
        }
        i = i + 1
    }
    return false
}


// list_models GETs {base}/api/tags and returns the names of the chat-capable installed models (so
// the app can offer them in a picker). An empty list means either no chat models are pulled or the
// daemon is not reachable — the caller treats both as "nothing to select, prompt the user".
fn list_models(base: string) -> [string] {
    var out: [string] = []
    let body = http.get("{base}/api/tags", "")
    match json.parse(body) {
        case Ok(v) {
            let models = json.get(v, "models")
            let n = json.length(models)
            var i = 0
            loop {
                if i == n {
                    break
                }
                let m = json.at(models, i)
                if _is_chat(m) {
                    let nm = json.as_str(json.get(m, "name"))
                    if nm.len() > 0 {
                        out.append(nm)
                    }
                }
                i = i + 1
            }
        }
        case Err(e) {}
    }
    return out
}


// build_request assembles an OpenAI-compatible /v1/chat/completions body from a transcript. A
// non-empty `system` becomes a leading system message; each Turn becomes one {role, content}
// message (role 0 → user, role 1 → assistant). Tool turns carry no tool wire format in this MVP —
// their visible text is kept as an ordinary message so context survives, and empty turns are
// dropped. `stream` selects SSE deltas vs a single blocking reply (the worker streams; tests don't).
fn build_request(model: string, max_tokens: int, system: string, turns: [api.Turn], stream: bool) -> string {
    var messages: [json.Json] = []
    if system.len() > 0 {
        messages.append(json.obj([
            json.member("role", json.str("system")),
            json.member("content", json.str(system))
        ]))
    }
    var i = 0
    loop {
        if i == turns.len() {
            break
        }
        let t = turns[i]
        if t.text.len() > 0 {
            var role = "assistant"
            if t.role == 0 {
                role = "user"
            }
            messages.append(json.obj([
                json.member("role", json.str(role)),
                json.member("content", json.str(t.text))
            ]))
        }
        i = i + 1
    }
    return json.stringify(json.obj([
        json.member("model", json.str(model)),
        json.member("max_tokens", json.num(max_tokens)),
        json.member("stream", json.boolean(stream)),
        json.member("messages", json.arr(messages))
    ]))
}


// _delta_text pulls the streamed token out of one SSE chunk: `choices[0].delta.content`. A chunk
// with no choices (the [DONE] sentinel, or a non-JSON keep-alive) yields "", appended as nothing.
fn _delta_text(resp: string) -> string {
    match json.parse(resp) {
        case Ok(v) {
            let choices = json.get(v, "choices")
            if json.length(choices) == 0 {
                return ""
            }
            return json.as_str(json.get(json.get(json.at(choices, 0), "delta"), "content"))
        }
        case Err(e) {
            return ""
        }
    }
}


// _err_text pulls a human message out of a non-stream error body — OpenAI-style {"error":{"message"}}
// first, then a plain {"error":"…"} string. "" when the body is not a recognisable error.
fn _err_text(raw: string) -> string {
    match json.parse(raw) {
        case Ok(v) {
            let m = json.as_str(json.get(json.get(v, "error"), "message"))
            if m.len() > 0 {
                return m
            }
            return json.as_str(json.get(v, "error"))
        }
        case Err(e) {
            return ""
        }
    }
}


// stream_worker is the async transport for Ollama, the twin of api.stream_worker: a long-lived fiber
// that parks on req_ch, opens a streaming POST to {base}/v1/chat/completions, pumps it on its own OS
// thread (parallel build), decodes SSE (std/sse), and forwards each delta's content to resp_ch as it
// arrives — then a done_mark. No tool path (MVP). `stop_ch` aborts the current reply between chunks;
// the caller closes req_ch at shutdown, waking the recv with None so the worker (and nursery) exit.
fn stream_worker(base: string, req_ch: Channel<string>, resp_ch: Channel<string>, stop_ch: Channel<bool>) {
    let url = "{base}/v1/chat/completions"
    let headers = "content-type: application/json\nauthorization: Bearer ollama\naccept: text/event-stream"
    loop {
        match recv(req_ch) {
            case Some(body) {
                loop {                                      // drain any stale stop signals from a prior turn
                    match try_recv(stop_ch) {
                        case Some(s) {}
                        case None { break }
                    }
                }
                let h = http.open(url, headers, body)
                var dec = sse.decoder()
                var got = false
                var raw = ""                                 // keep the raw body for the error path
                loop {
                    let chunk = http.next(h)
                    if chunk.len() == 0 {
                        break
                    }
                    raw = raw + chunk
                    let evs = dec.feed(chunk)
                    var i = 0
                    loop {
                        if i == evs.len() {
                            break
                        }
                        let t = _delta_text(evs[i].data)
                        if t.len() > 0 {
                            send(resp_ch, t)
                            got = true
                        }
                        i = i + 1
                    }
                    var stop = false                        // user hit Stop? abort between chunks
                    match try_recv(stop_ch) {
                        case Some(s) { stop = true }
                        case None {}
                    }
                    if stop {
                        break
                    }
                }
                if !got {
                    let st = http.status(h)
                    var detail = _err_text(raw)
                    if detail.len() == 0 && raw.len() > 0 {
                        detail = api.cap_text(raw, 400)
                    }
                    if detail.len() > 0 {
                        send(resp_ch, "Ollama request failed (HTTP {st}): {detail}")
                    } else {
                        send(resp_ch, "Ollama request failed (HTTP {st}) — is `ollama serve` running and the model pulled?")
                    }
                }
                let _ = http.close(h)
                send(resp_ch, api.done_mark())
            }
            case None {
                break
            }
        }
    }
}
