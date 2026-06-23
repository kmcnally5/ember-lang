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


fn main() -> int {
    // ---- build_request WITH a system prompt; an empty turn is dropped; roles map 0→user / 1→assistant ----
    var turns: [api.Turn] = []
    turns.append(api.mk_turn(0, "hello"))
    turns.append(api.mk_turn(1, "hi there"))
    turns.append(api.mk_turn(0, ""))                 // empty text → omitted from the OpenAI messages
    let body = oll.build_request("llama3.2", 2048, "be terse", turns, true)
    let bmodel = str_field(body, "model")
    let bstream = bool_field(body, "stream")
    let bn = nmsgs(body)
    let br0 = msg_role(body, 0)
    let br1 = msg_role(body, 1)
    let br2 = msg_role(body, 2)
    println("build: model={bmodel} stream={bstream} nmsg={bn} r0={br0} r1={br1} r2={br2}")

    // ---- build_request with NO system → no leading system message; stream flag is honoured ----
    let bare = oll.build_request("llama3.2", 1024, "", turns, false)
    let cn = nmsgs(bare)
    let cr0 = msg_role(bare, 0)
    let cstream = bool_field(bare, "stream")
    println("bare: nmsg={cn} r0={cr0} stream={cstream}")

    // ---- http.get fails gracefully on a refused connection (offline, deterministic) ----
    let refused = http.get("http://localhost:1/", "")
    let handled = has_curl_error(refused)
    println("httpget: refused_handled={handled}")
    return 0
}
