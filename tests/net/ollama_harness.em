// ollama_harness.em — regression for the local-Ollama client (public/claude-desktop/ollama.em). Like
// anthropic_harness, it exercises the PURE surface with no live server: the OpenAI-compatible request
// builder's shape (system message included only when non-empty, role mapping, empty turns dropped,
// the stream flag), plus that http.get fails GRACEFULLY (a refused localhost connection comes back as
// a `{"_curl_error":…}` string, never a crash). Offline and deterministic.
//
// Needs emberc-NET (the client imports std/http). Run via `make test-net` (tests/run-net.sh).
import "../../public/claude-desktop/ollama" as oll
import "../../public/claude-desktop/anthropic" as api
import "std/http" as http
import "std/json" as json


// str_field reads a top-level string field from a JSON object string ("?" if absent / unparsable).
fn str_field(body: string, key: string) -> string {
    match json.parse(body) {
        case Ok(v) {
            return json.as_str(json.get(v, key))
        }
        case Err(e) {
            return "?"
        }
    }
}


// bool_field reads a top-level bool field from a JSON object string (false if absent / unparsable).
fn bool_field(body: string, key: string) -> bool {
    match json.parse(body) {
        case Ok(v) {
            return json.as_bool(json.get(v, key))
        }
        case Err(e) {
            return false
        }
    }
}


// nmsgs returns the length of the request body's "messages" array (-1 if absent / unparsable).
fn nmsgs(body: string) -> int {
    match json.parse(body) {
        case Ok(v) {
            return json.length(json.get(v, "messages"))
        }
        case Err(e) {
            return 0 - 1
        }
    }
}


// msg_role returns messages[i].role from the request body ("?" if out of range / unparsable).
fn msg_role(body: string, i: int) -> string {
    match json.parse(body) {
        case Ok(v) {
            return json.as_str(json.get(json.at(json.get(v, "messages"), i), "role"))
        }
        case Err(e) {
            return "?"
        }
    }
}


// has_curl_error reports whether a string is the binding's failure sentinel `{"_curl_error":…}`.
fn has_curl_error(body: string) -> bool {
    match json.parse(body) {
        case Ok(v) {
            return !json.is_null(json.get(v, "_curl_error"))
        }
        case Err(e) {
            return false
        }
    }
}


// has_field reports whether a top-level key is present (and non-null) in a JSON object string.
fn has_field(body: string, key: string) -> bool {
    match json.parse(body) {
        case Ok(v) {
            return !json.is_null(json.get(v, key))
        }
        case Err(e) {
            return false
        }
    }
}


// tool0_fn_name reads tools[0].function.name from a request body ("?" if absent / unparsable).
fn tool0_fn_name(body: string) -> string {
    match json.parse(body) {
        case Ok(v) {
            let t0 = json.at(json.get(v, "tools"), 0)
            return json.as_str(json.get(json.get(t0, "function"), "name"))
        }
        case Err(e) {
            return "?"
        }
    }
}


// msg_tool_call_id reads messages[i].tool_call_id from a request body ("?" if absent / unparsable).
fn msg_tool_call_id(body: string, i: int) -> string {
    match json.parse(body) {
        case Ok(v) {
            return json.as_str(json.get(json.at(json.get(v, "messages"), i), "tool_call_id"))
        }
        case Err(e) {
            return "?"
        }
    }
}


// msg_has_tool_calls reports whether messages[i] carries a non-empty tool_calls array.
fn msg_has_tool_calls(body: string, i: int) -> bool {
    match json.parse(body) {
        case Ok(v) {
            return json.length(json.get(json.at(json.get(v, "messages"), i), "tool_calls")) > 0
        }
        case Err(e) {
            return false
        }
    }
}


// tool_chunk builds one synthetic OpenAI streaming chunk carrying a tool_calls[0] fragment, so the
// fragment-accumulation in feed_tool_call can be unit-tested offline (no live model). `id`/`name`
// empty → that field is omitted from the fragment (they arrive once); `args` is appended each call.
fn tool_chunk(id: string, name: string, args: string) -> string {
    var fnmembers: [json.Member] = [json.member("arguments", json.str(args))]
    if name.len() > 0 {
        fnmembers.append(json.member("name", json.str(name)))
    }
    var tc: [json.Member] = [
        json.member("index", json.num(0)),
        json.member("function", json.obj(fnmembers))
    ]
    if id.len() > 0 {
        tc.append(json.member("id", json.str(id)))
    }
    return json.stringify(json.obj([
        json.member("choices", json.arr([
            json.obj([json.member("delta", json.obj([
                json.member("tool_calls", json.arr([json.obj(tc)]))
            ]))])
        ]))
    ]))
}


fn main() -> int {
    // ---- build_request WITH a system prompt; an empty turn is dropped; roles map 0→user / 1→assistant ----
    var turns: [api.Turn] = []
    turns.append(api.mk_turn(0, "hello"))
    turns.append(api.mk_turn(1, "hi there"))
    turns.append(api.mk_turn(0, ""))                 // empty text → omitted from the OpenAI messages
    let body = oll.build_request("llama3.2", 2048, "be terse", turns, true, json.arr([]))
    let bmodel = str_field(body, "model")
    let bstream = bool_field(body, "stream")
    let bn = nmsgs(body)
    let br0 = msg_role(body, 0)
    let br1 = msg_role(body, 1)
    let br2 = msg_role(body, 2)
    let btools = has_field(body, "tools")            // no tools passed → no "tools" field
    println("build: model={bmodel} stream={bstream} nmsg={bn} r0={br0} r1={br1} r2={br2} tools={btools}")

    // ---- build_request with NO system → no leading system message; stream flag is honoured ----
    let bare = oll.build_request("llama3.2", 1024, "", turns, false, json.arr([]))
    let cn = nmsgs(bare)
    let cr0 = msg_role(bare, 0)
    let cstream = bool_field(bare, "stream")
    println("bare: nmsg={cn} r0={cr0} stream={cstream}")

    // ---- openai_tools reshapes an Anthropic catalogue → {type:function, function:{name,…}}; build_request attaches it ----
    let cat = json.arr([
        json.obj([
            json.member("name", json.str("read_file")),
            json.member("description", json.str("Read a file.")),
            json.member("input_schema", json.obj([
                json.member("type", json.str("object")),
                json.member("properties", json.obj([])),
                json.member("required", json.arr([]))
            ]))
        ])
    ])
    let oa = oll.openai_tools(cat)
    let treq = oll.build_request("llama3.2", 1024, "", turns, true, oa)
    println("tools: present={has_field(treq, "tools")} fn0={tool0_fn_name(treq)}")

    // ---- a tool_use turn (kind 1) → assistant message with tool_calls; a tool_result turn (kind 2) → role:"tool" ----
    var tt: [api.Turn] = []
    tt.append(api.mk_turn(0, "read x.txt"))
    tt.append(api.mk_tool_use("on it", "call_9", "read_file", "rawargs"))   // preamble + the call (opaque raw args)
    tt.append(api.mk_tool_result("call_9", "file body"))
    let tmap = oll.build_request("llama3.2", 1024, "", tt, false, oa)
    let m0 = msg_role(tmap, 0)
    let m1 = msg_role(tmap, 1)
    let m1tc = msg_has_tool_calls(tmap, 1)
    let m2 = msg_role(tmap, 2)
    let m2id = msg_tool_call_id(tmap, 2)
    println("toolmap: r0={m0} r1={m1} r1_calls={m1tc} r2={m2} r2_id={m2id}")

    // ---- feed_tool_call assembles a streamed call from fragments (id+name once, arguments concatenated) ----
    var acc = oll.tool_acc()
    acc = oll.feed_tool_call(acc, tool_chunk("call_7", "read_file", "AAA"))
    acc = oll.feed_tool_call(acc, tool_chunk("", "", "BBB"))
    acc = oll.feed_tool_call(acc, tool_chunk("", "", "CCC"))
    println("toolacc: id={acc.id} name={acc.name} args={acc.args} seen={acc.seen}")

    // ---- http.get fails gracefully on a refused connection (offline, deterministic) ----
    let refused = http.get("http://localhost:1/", "")
    let handled = has_curl_error(refused)
    println("httpget: refused_handled={handled}")
    return 0
}
