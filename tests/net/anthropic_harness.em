// anthropic_harness.em — regression for the reusable Anthropic client (public/claude-desktop/
// anthropic.em). It exercises the PURE protocol surface with NO network: the Turn constructors, the
// request builder's shape (system prompt + tools included only when supplied), the control-message
// round-trip (pack_tool → is_tool_msg → strip_tool_mark), cap_text, and the model-id constants.
//
// It needs emberc-NET because the client imports std/http (whose extern "c" bindings only link in the
// networking build); the test itself makes no request. Run via `make test-net` (tests/run-net.sh).
import "../../public/claude-desktop/anthropic" as api
import "std/json" as json


// has reports whether a top-level key is present (non-null) in a JSON object string.
fn has(body: string, key: string) -> bool {
    match json.parse(body) {
        case Ok(v) {
            return !json.is_null(json.get(v, key))
        }
        case Err(e) {
            return false
        }
    }
}


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


// starts_with reports whether `s` begins with `pfx` (code-point comparison).
fn starts_with(s: string, pfx: string) -> bool {
    let cs = s.chars()
    let pc = pfx.chars()
    if cs.len() < pc.len() {
        return false
    }
    var i = 0
    loop {
        if i == pc.len() {
            break
        }
        if cs[i] != pc[i] {
            return false
        }
        i = i + 1
    }
    return true
}


fn main() -> int {
    // ---- Turn constructors ----
    var turns: [api.Turn] = []
    turns.append(api.mk_turn(0, "hello"))
    turns.append(api.mk_turn(1, "hi there"))
    println("turns={turns.len()} role0={turns[0].role} kind0={turns[0].kind} role1={turns[1].role}")

    // ---- build_request WITH a system prompt and a tool catalogue ----
    let tools = json.arr([json.obj([json.member("name", json.str("read_file"))])])
    let body = api.build_request(api.MODEL_OPUS, 2048, "be terse", tools, turns)
    let hm = has(body, "model")
    let hs = has(body, "system")
    let ht = has(body, "tools")
    let hc = has(body, "tool_choice")
    let md = str_field(body, "model")
    println("full: model={hm} system={hs} tools={ht} tool_choice={hc} id={md}")

    // ---- build_request with NEITHER system NOR tools → both omitted, no tool_choice ----
    let bare = api.build_request(api.MODEL_HAIKU, 1024, "", json.arr([]), turns)
    let bs = has(bare, "system")
    let bt = has(bare, "tools")
    let bc = has(bare, "tool_choice")
    println("bare: system={bs} tools={bt} tool_choice={bc}")

    // ---- control-message round-trip: pack_tool → is_tool_msg → strip_tool_mark → parse ----
    let packed = api.pack_tool("toolu_42", "read_file", "ARGS")
    let im = api.is_tool_msg(packed)
    let ip = api.is_tool_msg("just text")
    var rid = "?"
    var rname = "?"
    var rinput = "?"
    match json.parse(api.strip_tool_mark(packed)) {
        case Ok(v) {
            rid = json.as_str(json.get(v, "id"))
            rname = json.as_str(json.get(v, "name"))
            rinput = json.as_str(json.get(v, "input"))
        }
        case Err(e) {}
    }
    println("ctl: is_tool={im} is_tool_plain={ip} id={rid} name={rname} input={rinput}")

    // ---- cap_text: short passes through, long is truncated with a note ----
    let short = api.cap_text("abc", 10)
    let capped = api.cap_text("abcdefghij", 4)
    let kept = starts_with(capped, "abcd")
    let noted = !starts_with(capped, "abcdefghij")
    println("cap: short={short} kept4={kept} truncated={noted}")

    // ---- model-id constants ----
    println("models: {api.MODEL_OPUS} | {api.MODEL_SONNET} | {api.MODEL_HAIKU}")
    return 0
}
