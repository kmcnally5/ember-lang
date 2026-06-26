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
// Scope: plain text chat PLUS OpenAI-style function calling for tool-capable local models (OFI-135) —
// build_request maps the transcript's tool turns and the stream worker assembles `tool_calls` deltas
// into the same packed-tool control message the Anthropic worker emits. The transcript MODEL (Turn) and
// the resp_ch control protocol (done_mark/tool_mark) are reused from anthropic.em so the app's one
// streaming drain loop + agentic loop work no matter which provider produced the reply.
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


// _has_tools reports whether a model entry from /api/tags advertises the "tools" capability — the
// signal that it can do OpenAI-style function calling. Many local models can't (it gates whether the
// app sends a tool catalogue at all, OFI-135). A daemon too old to report capabilities → false.
fn _has_tools(m: json.Json) -> bool {
    let caps = json.get(m, "capabilities")
    let n = json.length(caps)
    var i = 0
    loop {
        if i == n {
            break
        }
        if json.as_str(json.at(caps, i)) == "tools" {
            return true
        }
        i = i + 1
    }
    return false
}


// discover GETs {base}/api/tags and returns a small JSON envelope `{"models":[…], "tool_models":[…]}`:
// every chat-capable installed model, plus the subset that also advertises `tools`. It is the BLOCKING
// core (a 4s connect timeout when the daemon is down) — the app runs it on a worker fiber via
// disco_worker so the render thread never stalls (OFI-136). Both name lists are derived from one fetch.
fn discover(base: string) -> string {
    var names: [json.Json] = []
    var tools: [json.Json] = []
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
                        names.append(json.str(nm))
                        if _has_tools(m) {
                            tools.append(json.str(nm))
                        }
                    }
                }
                i = i + 1
            }
        }
        case Err(e) {}
    }
    return json.stringify(json.obj([
        json.member("models", json.arr(names)),
        json.member("tool_models", json.arr(tools))
    ]))
}


// _names_of pulls a string array out of a discover() envelope by field name ("models" or
// "tool_models"), returning the decoded names. A missing/unparsable envelope yields an empty list.
fn _names_of(envelope: string, field: string) -> [string] {
    var out: [string] = []
    match json.parse(envelope) {
        case Ok(v) {
            let arr = json.get(v, field)
            let n = json.length(arr)
            var i = 0
            loop {
                if i == n {
                    break
                }
                let nm = json.as_str(json.at(arr, i))
                if nm.len() > 0 {
                    out.append(nm)
                }
                i = i + 1
            }
        }
        case Err(e) {}
    }
    return out
}


// models_of / tool_models_of decode a discover() envelope: every chat model, and the tool-capable
// subset. The app keeps both — the first drives the picker, the second gates whether a turn carries
// tools (OFI-135). Pure string→[string], so the render loop can call them when the result lands.
fn models_of(envelope: string) -> [string] {
    return _names_of(envelope, "models")
}


fn tool_models_of(envelope: string) -> [string] {
    return _names_of(envelope, "tool_models")
}


// disco_worker is the async transport for model discovery (OFI-136): a long-lived fiber that parks on
// req_ch, runs the BLOCKING discover() on its own OS thread (so the 4s-when-down connect timeout never
// freezes the render thread), and forwards the JSON envelope on resp_ch. The app drains resp_ch with
// try_recv. Closing req_ch at shutdown wakes the recv with None so the worker (and nursery) exit.
fn disco_worker(base_ch: Channel<string>, resp_ch: Channel<string>) {
    loop {
        match recv(base_ch) {
            case Some(base) {
                send(resp_ch, discover(base))
            }
            case None {
                break
            }
        }
    }
}


// openai_tools reshapes the app's Anthropic-style tool catalogue (`{name, description, input_schema}`)
// into OpenAI/Ollama function-calling form (`{type:"function", function:{name, description, parameters}}`)
// — the JSON Schema body is identical, only the envelope differs, so the app keeps ONE tool definition
// (OFI-135). An empty input yields an empty array (the caller then omits `tools` entirely).
fn openai_tools(tools: json.Json) -> json.Json {
    var out: [json.Json] = []
    let n = json.length(tools)
    var i = 0
    loop {
        if i == n {
            break
        }
        let t = json.at(tools, i)
        out.append(json.obj([
            json.member("type", json.str("function")),
            json.member("function", json.obj([
                json.member("name", json.get(t, "name")),
                json.member("description", json.get(t, "description")),
                json.member("parameters", json.get(t, "input_schema"))
            ]))
        ]))
        i = i + 1
    }
    return json.arr(out)
}


// build_request assembles an OpenAI-compatible /v1/chat/completions body from a transcript. A
// non-empty `system` becomes a leading system message; a plain Turn → one {role, content} message
// (role 0 → user, role 1 → assistant). A tool_use Turn (kind 1) → an assistant message carrying
// `tool_calls` (the call the model made); a tool_result Turn (kind 2) → a `{role:"tool", tool_call_id,
// content}` message — so a multi-step agentic loop replays correctly to a tool-capable local model
// (OFI-135). `tools` (OpenAI-format, from openai_tools) is attached only when non-empty; empty Turns
// are dropped. `stream` selects SSE deltas vs a single blocking reply (the worker streams; tests don't).
fn build_request(model: string, max_tokens: int, system: string, turns: [api.Turn], stream: bool, tools: json.Json) -> string {
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
        if t.kind == 1 {
            // assistant tool call → {role:assistant, content:<preamble>, tool_calls:[{id,function:{name,arguments}}]}
            messages.append(json.obj([
                json.member("role", json.str("assistant")),
                json.member("content", json.str(t.text)),
                json.member("tool_calls", json.arr([
                    json.obj([
                        json.member("id", json.str(t.tool_id)),
                        json.member("type", json.str("function")),
                        json.member("function", json.obj([
                            json.member("name", json.str(t.tool_name)),
                            json.member("arguments", json.str(t.tool_input))
                        ]))
                    ])
                ]))
            ]))
        } else if t.kind == 2 {
            // our tool result → {role:tool, tool_call_id, content}
            messages.append(json.obj([
                json.member("role", json.str("tool")),
                json.member("tool_call_id", json.str(t.tool_id)),
                json.member("content", json.str(t.text))
            ]))
        } else if t.text.len() > 0 {
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
    var body: [json.Member] = [
        json.member("model", json.str(model)),
        json.member("max_tokens", json.num(max_tokens)),
        json.member("stream", json.boolean(stream)),
        json.member("messages", json.arr(messages))
    ]
    if json.length(tools) > 0 {
        body.append(json.member("tools", tools))
    }
    return json.stringify(json.obj(body))
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


// A streamed tool call, assembled across SSE deltas (OFI-135). OpenAI/Ollama send a tool call in
// fragments: the id + function name arrive once (typically the first delta), the JSON `arguments`
// string streams across many. We accumulate index 0 — the app runs ONE tool per reply, like the
// Anthropic path's disable_parallel_tool_use; `seen` records that any tool_call fragment appeared.
struct ToolAcc {
    id: string
    name: string
    args: string
    seen: bool
}


// tool_acc starts an empty accumulator.
fn tool_acc() -> ToolAcc {
    return ToolAcc { id: "", name: "", args: "", seen: false }
}


// feed_tool_call folds one SSE chunk's `choices[0].delta.tool_calls[0]` into the accumulator: a fresh
// id/name replaces (they arrive once), an `arguments` fragment appends. A chunk with no tool_calls is
// returned unchanged. PURE (acc in → acc out) so the streaming assembly is unit-testable offline.
fn feed_tool_call(move acc: ToolAcc, resp: string) -> ToolAcc {
    match json.parse(resp) {
        case Ok(v) {
            let choices = json.get(v, "choices")
            if json.length(choices) == 0 {
                return acc
            }
            let tcs = json.get(json.get(json.at(choices, 0), "delta"), "tool_calls")
            if json.length(tcs) == 0 {
                return acc
            }
            let tc = json.at(tcs, 0)
            var id = acc.id
            let nid = json.as_str(json.get(tc, "id"))
            if nid.len() > 0 {
                id = nid
            }
            let f = json.get(tc, "function")
            var name = acc.name
            let nn = json.as_str(json.get(f, "name"))
            if nn.len() > 0 {
                name = nn
            }
            let frag = json.as_str(json.get(f, "arguments"))
            return ToolAcc { id: id, name: name, args: acc.args + frag, seen: true }
        }
        case Err(e) {
            return acc
        }
    }
}


// stream_worker is the async transport for Ollama, the twin of api.stream_worker: a long-lived fiber
// that parks on req_ch, opens a streaming POST to {base}/v1/chat/completions, pumps it on its own OS
// thread (parallel build), decodes SSE (std/sse), forwards each delta's content to resp_ch as it
// arrives, then — if the model called a tool — a packed tool message, then a done_mark (FIFO order
// guarantees the tool call is drained before the done that triggers it, OFI-135). `stop_ch` aborts the
// current reply between chunks; the caller closes req_ch at shutdown, waking recv with None so it exits.
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
                var tacc = tool_acc()                       // a tool call assembled across deltas (OFI-135)
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
                        tacc = feed_tool_call(tacc, evs[i].data)
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
                if tacc.seen && tacc.name.len() > 0 {
                    // The model called a tool: hand it to the app's agentic loop (it runs the tool +
                    // re-sends). Some local models omit the call id → synthesize a stable one.
                    var tid = tacc.id
                    if tid.len() == 0 {
                        tid = "call_1"
                    }
                    send(resp_ch, api.pack_tool(tid, tacc.name, tacc.args))
                    got = true                               // a tool call is a successful (non-empty) reply
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
