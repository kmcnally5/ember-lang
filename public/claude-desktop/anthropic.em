// anthropic.em — a reusable client for the Anthropic Messages API, lifted out of the Claude
// desktop app so any Ember program can talk to Claude without reinventing the wire format. It
// owns three things: the conversation MODEL (the Turn struct + constructors), the REQUEST builder
// (build_request — multi-turn, optional system prompt, app-supplied tool catalogue), and the
// async STREAMING TRANSPORT (stream_worker — a fiber that pumps an SSE stream over std/http and
// multiplexes text deltas and tool calls onto one channel). The vendor specifics live here; the
// generic transport is std/http and the SSE framing is std/sse.
//
// Needs the networking build (it imports std/http) — `make net` (CLI) or `make net-graphics`
// (GUI). Import it from a sibling file: `import "anthropic" as api`.
import "std/http" as http
import "std/sse" as sse
import "std/json" as json
import "std/string" as str


// The current Claude model ids (knowledge cutoff: 2026-01). Use these instead of hardcoding
// strings, so a model refresh is a one-line change here that every caller inherits.
let MODEL_OPUS   = "claude-opus-4-8"
let MODEL_SONNET = "claude-sonnet-4-6"
let MODEL_HAIKU  = "claude-haiku-4-5-20251001"


// Turn is one message in a conversation — Anthropic's content-block model flattened to one block
// per Turn:
//   kind 0 = plain text          (role 0 you / role 1 Claude; `text` is the message)
//   kind 1 = tool_use            (role 1 Claude; `text` = any preamble, + tool_id/name/input)
//   kind 2 = tool_result         (role 0 us; `text` = the tool's output, tool_id = the call it answers)
// `disable_parallel_tool_use` keeps it to at most one tool_use per assistant reply, so one block
// per Turn holds.
struct Turn {
    role: int
    text: string
    kind: int
    tool_id: string
    tool_name: string
    tool_input: string
}


// mk_turn builds a plain text Turn (kind 0) — the everyday message, user or assistant.
fn mk_turn(role: int, text: string) -> Turn {
    return Turn { role: role, text: text, kind: 0, tool_id: "", tool_name: "", tool_input: "" }
}


// mk_tool_use builds the assistant turn where Claude calls a tool (kind 1): `text` is any spoken
// preamble, then the call (id / name / raw-JSON args). Always role 1 (the assistant).
fn mk_tool_use(text: string, id: string, name: string, input: string) -> Turn {
    return Turn { role: 1, text: text, kind: 1, tool_id: id, tool_name: name, tool_input: input }
}


// mk_tool_result builds OUR turn handing the tool's output back (kind 2): role 0 (it rides a user
// message in the API), `text` = the result, `tool_id` = the tool_use id it answers.
fn mk_tool_result(id: string, result: string) -> Turn {
    return Turn { role: 0, text: result, kind: 2, tool_id: id, tool_name: "", tool_input: "" }
}


// mk_turn_full builds a Turn from all six fields at once — the constructor for rehydrating a
// persisted transcript (every field read back from storage), where mk_turn/mk_tool_* would lose
// information. Equivalent to the struct literal, but keeps the Turn shape private to this module.
fn mk_turn_full(role: int, text: string, kind: int, tool_id: string, tool_name: string, tool_input: string) -> Turn {
    return Turn { role: role, text: text, kind: kind, tool_id: tool_id, tool_name: tool_name, tool_input: tool_input }
}


// build_request assembles the Messages-API body from a transcript. Each Turn becomes one message:
// a plain text turn → string content; a tool_use turn → `[text?, tool_use]` blocks; a tool_result
// turn → a `tool_result` block. `system` adds a system prompt when non-empty; `tools` is the
// app's tool catalogue (a JSON array) — when empty, neither `tools` nor `tool_choice` is sent, so
// a tool-less app gets a clean request. Built as a std/json tree and serialized, so all escaping
// (quotes, newlines, unicode) is the library's job.
fn build_request(model: string, max_tokens: int, system: string, tools: json.Json, turns: [Turn]) -> string {
    var messages: [json.Json] = []
    var i = 0
    loop {
        if i == turns.len() {
            break
        }
        var role = "assistant"
        if turns[i].role == 0 {
            role = "user"
        }
        var content = json.str(turns[i].text)            // kind 0: plain string content
        if turns[i].kind == 1 {                          // assistant tool_use → [optional text block, tool_use block]
            var blocks: [json.Json] = []
            if turns[i].text.len() > 0 {
                blocks.append(json.obj([
                    json.member("type", json.str("text")),
                    json.member("text", json.str(turns[i].text))
                ]))
            }
            var args = json.obj([])                      // re-parse the raw accumulated args back into a JSON value
            match json.parse(turns[i].tool_input) {
                case Ok(v) {
                    args = v
                }
                case Err(e) {}
            }
            blocks.append(json.obj([
                json.member("type", json.str("tool_use")),
                json.member("id", json.str(turns[i].tool_id)),
                json.member("name", json.str(turns[i].tool_name)),
                json.member("input", args)
            ]))
            content = json.arr(blocks)
        }
        if turns[i].kind == 2 {                          // our tool_result → a single tool_result block
            content = json.arr([
                json.obj([
                    json.member("type", json.str("tool_result")),
                    json.member("tool_use_id", json.str(turns[i].tool_id)),
                    json.member("content", json.str(turns[i].text))
                ])
            ])
        }
        messages.append(json.obj([
            json.member("role", json.str(role)),
            json.member("content", content)
        ]))
        i = i + 1
    }
    var members: [json.Member] = [
        json.member("model", json.str(model)),
        json.member("max_tokens", json.num(max_tokens)),
        json.member("stream", json.boolean(true)),
        json.member("messages", json.arr(messages))
    ]
    if system.len() > 0 {                                // optional system prompt
        members.append(json.member("system", json.str(system)))
    }
    if json.length(tools) > 0 {                          // advertise tools only when the app supplies some
        members.append(json.member("tools", tools))
        members.append(json.member("tool_choice", json.obj([
            json.member("type", json.str("auto")),
            json.member("disable_parallel_tool_use", json.boolean(true))
        ])))
    }
    return json.stringify(json.obj(members))
}


// extract_text pulls the assistant text out of one streamed event's JSON via std/json: a
// `content_block_delta`'s `delta.text`, or an API error body's `error.message`. Anything else (a
// non-text event, or a partial/!JSON chunk) yields "", which the caller appends as nothing.
fn extract_text(resp: string) -> string {
    match json.parse(resp) {
        case Ok(v) {
            let t = json.as_str(json.get(json.get(v, "delta"), "text"))
            if t.len() > 0 {
                return t
            }
            let m = json.as_str(json.get(json.get(v, "error"), "message"))
            if m.len() > 0 {
                return "API error: {m}"
            }
            return ""
        }
        case Err(e) {
            return ""
        }
    }
}


// done_mark marks the end of one streamed reply on resp_ch (a control byte that never appears in text).
fn done_mark() -> string {
    return from_char_code(4)
}


// tool_mark prefixes a tool-use control message on resp_ch (STX, char 2 — never appears in reply text, and
// distinct from done_mark's char 4). The transport multiplexes text deltas and tool calls on the one channel;
// FIFO order then guarantees a tool call is drained BEFORE the done_mark that follows it.
fn tool_mark() -> string {
    return from_char_code(2)
}


// pack_tool serialises a streamed tool_use block into the control message the main loop unpacks: the mark
// then {id, name, input} (input kept as the RAW args JSON string — re-sent verbatim and parsed for execution).
fn pack_tool(id: string, name: string, input: string) -> string {
    return tool_mark() + json.stringify(json.obj([
        json.member("id", json.str(id)),
        json.member("name", json.str(name)),
        json.member("input", json.str(input))
    ]))
}


// is_tool_msg recognises a resp_ch control message (leading tool_mark).
fn is_tool_msg(d: string) -> bool {
    if d.len() == 0 {
        return false
    }
    return str.substring(d, 0, 1) == tool_mark()
}


// strip_tool_mark unwraps a control message, returning the JSON after the leading tool_mark.
fn strip_tool_mark(d: string) -> string {
    return str.substring(d, 1, 1000000)
}


// arg_str pulls a string argument out of a tool's raw JSON-args string. "" if absent or the args don't parse.
fn arg_str(input: string, key: string) -> string {
    match json.parse(input) {
        case Ok(v) {
            return json.as_str(json.get(v, key))
        }
        case Err(e) {
            return ""
        }
    }
}


// cap_text bounds a string to `n` code points, appending a truncation note when it trims — a safety valve so a
// huge file can't blow the request (and the model is told it was cut). Returns the input untouched when it fits.
fn cap_text(s: string, n: int) -> string {
    let cs = s.chars()
    if cs.len() <= n {
        return s
    }
    return str.substring(s, 0, n) + "\n… [truncated — {cs.len()} chars total]"
}


// stream_worker is the async STREAMING transport: a long-lived fiber that parks on req_ch, opens a
// streaming POST (std/http), pumps it on its own OS thread (parallel build), decodes SSE (std/sse), and
// forwards each `content_block_delta`'s text to resp_ch as it arrives — then a done_mark. A completed
// tool_use block is packed onto resp_ch as a control message. The caller closes req_ch at shutdown,
// waking the recv with None so the worker (and its nursery) exit. `stop_ch` aborts the current reply.
fn stream_worker(api_key: string, req_ch: Channel<string>, resp_ch: Channel<string>, stop_ch: Channel<bool>) {
    let headers = "content-type: application/json\nanthropic-version: 2023-06-01\nx-api-key: {api_key}\naccept: text/event-stream"
    loop {
        match recv(req_ch) {
            case Some(body) {
                loop {                                      // drain any stale stop signals from a prior turn
                    match try_recv(stop_ch) {
                        case Some(s) {}
                        case None { break }
                    }
                }
                let h = http.open("https://api.anthropic.com/v1/messages", headers, body)
                var dec = sse.decoder()
                var got = false
                var raw = ""                                 // keep the raw body for the error path
                var cur_is_tool = false                      // the content block in flight is a tool_use…
                var cur_tool_id = ""                         // …its id / name / accumulating raw-JSON args
                var cur_tool_name = ""
                var cur_tool_input = ""
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
                        let nm = evs[i].name
                        if nm == "content_block_start" {     // a new block: text, or a tool_use (capture id/name)
                            match json.parse(evs[i].data) {
                                case Ok(v) {
                                    let cb = json.get(v, "content_block")
                                    if json.as_str(json.get(cb, "type")) == "tool_use" {
                                        cur_is_tool = true
                                        cur_tool_id = json.as_str(json.get(cb, "id"))
                                        cur_tool_name = json.as_str(json.get(cb, "name"))
                                        cur_tool_input = ""
                                    } else {
                                        cur_is_tool = false
                                    }
                                }
                                case Err(e) {}
                            }
                        }
                        if nm == "content_block_delta" {     // text_delta → forward; input_json_delta → accumulate args
                            match json.parse(evs[i].data) {
                                case Ok(v) {
                                    let delta = json.get(v, "delta")
                                    if json.as_str(json.get(delta, "type")) == "input_json_delta" {
                                        cur_tool_input = cur_tool_input + json.as_str(json.get(delta, "partial_json"))
                                    } else {
                                        let t = json.as_str(json.get(delta, "text"))
                                        if t.len() > 0 {
                                            send(resp_ch, t)
                                            got = true
                                        }
                                    }
                                }
                                case Err(e) {}
                            }
                        }
                        if nm == "content_block_stop" {      // a tool_use block just closed → emit the complete call
                            if cur_is_tool {
                                send(resp_ch, pack_tool(cur_tool_id, cur_tool_name, cur_tool_input))
                                got = true
                                cur_is_tool = false
                            }
                        }
                        if nm == "error" {                   // a streamed API error — surface it immediately, verbatim
                            match json.parse(evs[i].data) {
                                case Ok(v) {
                                    let em = json.as_str(json.get(json.get(v, "error"), "message"))
                                    if em.len() > 0 {
                                        send(resp_ch, "API error: {em}")
                                        got = true
                                    }
                                }
                                case Err(e) {}
                            }
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
                    var detail = extract_text(raw)                  // a clean error.message if the body is a JSON error
                    if detail.len() == 0 && raw.len() > 0 {
                        detail = cap_text(raw, 400)                 // otherwise show the raw body so the real cause is visible
                    }
                    if detail.len() > 0 {
                        send(resp_ch, "Request failed (HTTP {st}): {detail}")     // the API's ACTUAL reason — not a guess about the key
                    } else {
                        send(resp_ch, "Request failed (HTTP {st}) — empty response from the server (network/proxy, or the request never left).")
                    }
                }
                let _ = http.close(h)
                send(resp_ch, done_mark())
            }
            case None {
                break
            }
        }
    }
}
